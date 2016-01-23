{-# LANGUAGE OverloadedStrings, TupleSections, FlexibleContexts #-}
-- | This program is a convenience utility for running the Futhark
-- test suite, and its test programs.
module Main ( ProgramTest (..)
            , TestRun (..)
            , TestCase (..)
            , main) where

import Control.Category ((>>>))
import Control.Applicative
import Control.Concurrent
import Control.Monad hiding (forM_)
import Control.Exception hiding (try)
import Control.Monad.Except hiding (forM_)
import Data.Char
import Data.List hiding (foldl')
import Data.Monoid
import Data.Ord
import Data.Foldable (forM_, foldl')
import qualified Data.Array as A
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.HashMap.Lazy as HM
import System.Console.GetOpt
import System.Directory
import System.Process
import System.Exit
import System.IO
import System.FilePath

import Text.Parsec hiding ((<|>), many, optional)
import Text.Parsec.Text
import Text.Parsec.Error
import Text.Regex.TDFA

import Prelude

import Futhark.Util.Pretty (Pretty,pretty)
import Futhark.Representation.AST.Syntax.Core hiding (Prim)
import Futhark.Internalise.TypesValues (internaliseValue)
import qualified Language.Futhark.Parser as F
import Futhark.Representation.SOACS (SOACS)
import Futhark.Representation.Kernels (Kernels)
import Futhark.Representation.AST.Attributes.Values (valueType)
import Futhark.Analysis.Metrics
import Futhark.Pipeline
import Futhark.Compiler
import Futhark.Pass.Simplify
import Futhark.Pass.ExtractKernels
import Futhark.Passes
import Futhark.Util.Log

import Futhark.Util.Options

---
--- Test specification parser
---

-- | Description of a test to be carried out on a Futhark program.
-- The Futhark program is stored separately.
data ProgramTest =
  ProgramTest { testDescription ::
                   T.Text
              , testTags ::
                   [T.Text]
              , testAction ::
                   TestAction
              , testExpectedStructure ::
                   Maybe StructureTest
              }
  deriving (Show)

data TestAction
  = CompileTimeFailure ExpectedError
  | RunCases [TestRun]
  deriving (Show)

data ExpectedError = AnyError
                   | ThisError T.Text Regex

instance Show ExpectedError where
  show AnyError = "AnyError"
  show (ThisError r _) = "ThisError " ++ show r

data StructurePipeline = KernelsPipeline (Pipeline SOACS Kernels)
                       | SOACSPipeline (Pipeline SOACS SOACS)

data StructureTest = StructureTest StructurePipeline AstMetrics

instance Show StructureTest where
  show (StructureTest _ metrics) =
    "StructureTest <config> " ++ show metrics

data RunMode
  = CompiledOnly
  | InterpretedOnly
  | InterpretedAndCompiled
  deriving (Eq, Show)

data TestRun = TestRun
               { runMode :: RunMode
               , runInput :: Values
               , runExpectedResult :: ExpectedResult Values
               }
             deriving (Show)

data Values = Values [Value]
            | InFile FilePath
            deriving (Show)

data ExpectedResult values
  = Succeeds values
  | RunTimeFailure ExpectedError
  deriving (Show)

lexeme :: Parser a -> Parser a
lexeme p = p <* spaces

lexstr :: String -> Parser ()
lexstr = void . lexeme . string

braces :: Parser a -> Parser a
braces p = lexstr "{" *> p <* lexstr "}"

parseNatural :: Parser Int
parseNatural = lexeme $ foldl' (\acc x -> acc * 10 + x) 0 <$>
               map num <$> some digit
  where num c = ord c - ord '0'

parseDescription :: Parser T.Text
parseDescription = lexeme $ T.pack <$> (anyChar `manyTill` parseDescriptionSeparator)

parseDescriptionSeparator :: Parser ()
parseDescriptionSeparator = try (string descriptionSeparator >> void newline) <|> eof

descriptionSeparator :: String
descriptionSeparator = "=="

parseTags :: Parser [T.Text]
parseTags = lexstr "tags" *> braces (many parseTag) <|> pure []
  where parseTag = T.pack <$> lexeme (many1 $ satisfy constituent)
        constituent c = not (isSpace c) && c /= '}'

parseAction :: Parser TestAction
parseAction = CompileTimeFailure <$> (lexstr "error:" *> parseExpectedError) <|>
              RunCases <$> parseRunCases

parseRunMode :: Parser RunMode
parseRunMode = (lexstr "compiled" *> pure CompiledOnly) <|>
               pure InterpretedAndCompiled

parseRunCases :: Parser [TestRun]
parseRunCases = many $ TestRun <$> parseRunMode <*> parseInput <*> parseExpectedResult

parseExpectedResult :: Parser (ExpectedResult Values)
parseExpectedResult = (Succeeds <$> (lexstr "output" *> parseValues)) <|>
                 (RunTimeFailure <$> (lexstr "error:" *> parseExpectedError))

parseExpectedError :: Parser ExpectedError
parseExpectedError = lexeme $ do
  s <- restOfLine
  if T.all isSpace s
    then return AnyError
         -- blankCompOpt creates a regular expression that treats
         -- newlines like ordinary characters, which is what we want.
    else ThisError s <$> makeRegexOptsM blankCompOpt defaultExecOpt (T.unpack s)

parseInput :: Parser Values
parseInput = lexstr "input" *> parseValues

parseValues :: Parser Values
parseValues = do s <- parseBlock
                 case parseValuesFromString "input" $ T.unpack s of
                   Left err -> fail $ show err
                   Right vs -> return $ Values vs
              <|> lexstr "@" *> lexeme (InFile <$> T.unpack <$> restOfLine)

parseValuesFromString :: SourceName -> String -> Either F.ParseError [Value]
parseValuesFromString srcname s =
  liftM concat $ mapM internalise =<< F.parseValues F.RealAsFloat64 srcname s
  where internalise v =
          maybe (Left $ F.ParseError $ "Invalid input value: " ++ pretty v) Right $
          internaliseValue v

parseBlock :: Parser T.Text
parseBlock = lexeme $ braces (T.pack <$> parseBlockBody 0)

parseBlockBody :: Int -> Parser String
parseBlockBody n = do
  c <- lookAhead anyChar
  case (c,n) of
    ('}', 0) -> return mempty
    ('}', _) -> (:) <$> anyChar <*> parseBlockBody (n-1)
    ('{', _) -> (:) <$> anyChar <*> parseBlockBody (n+1)
    _        -> (:) <$> anyChar <*> parseBlockBody n

restOfLine :: Parser T.Text
restOfLine = T.pack <$> (anyChar `manyTill` (void newline <|> eof))

parseExpectedStructure :: Parser StructureTest
parseExpectedStructure =
  lexstr "structure" *>
  (StructureTest <$> optimisePipeline <*> parseMetrics)

optimisePipeline :: Parser StructurePipeline
optimisePipeline = lexstr "distributed" *> pure distributePipelineConfig <|>
                   pure defaultPipelineConfig
  where defaultPipelineConfig =
          SOACSPipeline standardPipeline
        distributePipelineConfig =
          KernelsPipeline $
          standardPipeline >>>
          onePass extractKernels >>>
          onePass simplifyKernels

parseMetrics :: Parser AstMetrics
parseMetrics = braces $ liftM HM.fromList $ many $
               (,) <$> (T.pack <$> lexeme (many1 (satisfy constituent))) <*> parseNatural
  where constituent c = isAlpha c || c == '/'

testSpec :: Parser ProgramTest
testSpec =
  ProgramTest <$> parseDescription <*> parseTags <*> parseAction <*> optional parseExpectedStructure

readTestSpec :: SourceName -> T.Text -> Either ParseError ProgramTest
readTestSpec = parse $ testSpec <* eof

commentPrefix :: T.Text
commentPrefix = "--"

fixPosition :: ParseError -> ParseError
fixPosition err =
  let newpos = incSourceColumn (errorPos err) $ T.length commentPrefix
  in setErrorPos newpos err

testSpecFromFile :: FilePath -> IO ProgramTest
testSpecFromFile path = do
  s <- T.unlines <$>
       map (T.drop 2) <$>
       takeWhile (commentPrefix `T.isPrefixOf`) <$>
       T.lines <$>
       T.readFile path
  case readTestSpec path s of
    Left err -> error $ show $ fixPosition err
    Right v  -> return v

---
--- Test execution
---

type TestM = ExceptT String IO

runTestM :: TestM () -> IO TestResult
runTestM = liftM (either Failure $ const Success) . runExceptT

io :: IO a -> TestM a
io = liftIO

context :: String -> TestM a -> TestM a
context s = withExceptT ((s ++ ":\n") ++)

data TestResult = Success
                | Failure String
                deriving (Eq, Show)

data TestCase = TestCase { testCaseProgram :: FilePath
                         , testCaseTest :: ProgramTest
                         , testCasePrograms :: ProgConfig
                         }
                deriving (Show)

instance Eq TestCase where
  x == y = testCaseProgram x == testCaseProgram y

instance Ord TestCase where
  x `compare` y = testCaseProgram x `compare` testCaseProgram y

data RunResult = ErrorResult Int String
               | SuccessResult [Value]

progNotFound :: String -> String
progNotFound s = s ++ ": command not found"

optimisedProgramMetrics :: StructurePipeline -> FilePath -> TestM AstMetrics
optimisedProgramMetrics (SOACSPipeline pipeline) program = do
  res <- io $ runFutharkM $ runPipelineOnProgram newFutharkConfig pipeline program
  case res of
    (Left err, msgs) ->
      throwError $ T.unpack $ T.unlines [toText msgs, errorDesc err]
    (Right prog, _) ->
      return $ progMetrics prog
optimisedProgramMetrics (KernelsPipeline pipeline) program = do
  res <- io $ runFutharkM $ runPipelineOnProgram newFutharkConfig pipeline program
  case res of
    (Left err, msgs) ->
      throwError $ T.unpack $ T.unlines [toText msgs, errorDesc err]
    (Right prog, _) ->
      return $ progMetrics prog

testMetrics :: FilePath -> StructureTest -> TestM ()
testMetrics program (StructureTest pipeline expected) = context "Checking metrics" $ do
  actual <- optimisedProgramMetrics pipeline program
  mapM_ (ok actual) $ HM.toList expected
  where ok metrics (name, expected_occurences) =
          case HM.lookup name metrics of
            Nothing
              | expected_occurences > 0 ->
              throwError $ T.unpack name ++ " should have occurred " ++ show expected_occurences ++
              " times, but did not occur at all in optimised program."
            Just actual_occurences
              | expected_occurences /= actual_occurences ->
                throwError $ T.unpack name ++ " should have occurred " ++ show expected_occurences ++
              " times, but occured " ++ show actual_occurences ++ " times."
            _ -> return ()

runTestCase :: TestCase -> TestM ()
runTestCase (TestCase program testcase progs) = do
  forM_ (testExpectedStructure testcase) $ testMetrics program

  case testAction testcase of

    CompileTimeFailure expected_error ->
      forM_ (configTypeCheckers progs) $ \typeChecker ->
        context ("Type-checking with " ++ typeChecker) $ do
          (code, _, err) <-
            io $ readProcessWithExitCode typeChecker [program] ""
          case code of
           ExitSuccess -> throwError "Expected failure\n"
           ExitFailure 127 -> throwError $ progNotFound typeChecker
           ExitFailure 1 -> throwError err
           ExitFailure _ -> checkError expected_error err

    RunCases [] ->
      forM_ (configCompilers progs) $ \compiler ->
      context ("Compiling with " ++ compiler) $
      justCompileTestProgram compiler program

    RunCases run_cases ->
      forM_ run_cases $ \run -> do
        unless (runMode run == CompiledOnly) $
          forM_ (configInterpreters progs) $ \interpreter ->
            context ("Interpreting with " ++ interpreter) $
              interpretTestProgram interpreter program run

        unless (runMode run == InterpretedOnly) $
          forM_ (configCompilers progs) $ \compiler ->
            context ("Compiling with " ++ compiler) $
              compileTestProgram compiler program run

checkError :: ExpectedError -> String -> TestM ()
checkError (ThisError regex_s regex) err
  | not (match regex err) =
     throwError $ "Expected error:\n  " ++ T.unpack regex_s ++
     "\nGot error:\n  " ++ err
checkError _ _ =
  return ()

runResult :: FilePath -> ExitCode -> String -> String -> TestM RunResult
runResult program ExitSuccess stdout_s _ =
  case parseValuesFromString "stdout" stdout_s of
    Left e   -> do
      actual <- io $ writeOutFile program "actual" stdout_s
      throwError $ show e <> "\n(See " <> actual <> ")"
    Right vs -> return $ SuccessResult vs
runResult _ (ExitFailure code) _ stderr_s =
  return $ ErrorResult code stderr_s

getValues :: MonadIO m => FilePath -> Values -> m [Value]
getValues _ (Values vs) =
  return vs
getValues dir (InFile file) = do
  s <- liftIO $ readFile file'
  case parseValuesFromString file' s of
    Left e   -> fail $ show e
    Right vs -> return vs
  where file' = dir </> file

getExpectedResult :: MonadIO m =>
                     FilePath -> ExpectedResult Values -> m (ExpectedResult [Value])
getExpectedResult dir (Succeeds vals)      = liftM Succeeds $ getValues dir vals
getExpectedResult _   (RunTimeFailure err) = return $ RunTimeFailure err

interpretTestProgram :: String -> FilePath -> TestRun -> TestM ()
interpretTestProgram futharki program (TestRun _ inputValues expectedResult) = do
  input <- intercalate "\n" <$> map pretty <$> getValues dir inputValues
  expectedResult' <- getExpectedResult dir expectedResult
  (code, output, err) <- io $ readProcessWithExitCode futharki [program] input
  case code of
    ExitFailure 127 ->
      throwError $ progNotFound futharki
    _               ->
      compareResult program expectedResult' =<< runResult program code output err
  where dir = takeDirectory program

compileTestProgram :: String -> FilePath -> TestRun -> TestM ()
compileTestProgram futharkc program (TestRun _ inputValues expectedResult) = do
  input <- intercalate "\n" <$> map pretty <$> getValues dir inputValues
  expectedResult' <- getExpectedResult dir expectedResult
  (futcode, _, futerr) <-
    io $ readProcessWithExitCode futharkc
    [program, "-o", binOutputf] ""
  case futcode of
    ExitFailure 127 -> throwError $ progNotFound futharkc
    ExitFailure _   -> throwError futerr
    ExitSuccess     -> return ()
  -- Explicitly prefixing the current directory is necessary for
  -- readProcessWithExitCode to find the binary when binOutputf has
  -- no path component.
  (progCode, output, progerr) <-
    io $ readProcessWithExitCode ("." </> binOutputf) [] input
  withExceptT validating $
    compareResult program expectedResult' =<< runResult program progCode output progerr
  where binOutputf = program `replaceExtension` "bin"
        dir = takeDirectory program
        validating = ("validating test result:\n"++)

justCompileTestProgram :: String -> FilePath -> TestM ()
justCompileTestProgram futharkc program =
  withExceptT compiling $ do
    (futcode, _, futerr) <-
      io $ readProcessWithExitCode futharkc
      [program, "-o", binOutputf] ""
    case futcode of
      ExitFailure 127 -> throwError $ progNotFound futharkc
      ExitFailure _   -> throwError futerr
      ExitSuccess     -> return ()
  where binOutputf = program `replaceExtension` "bin"

        compiling = ("compiling:\n"++)

compareResult :: FilePath -> ExpectedResult [Value] -> RunResult -> TestM ()
compareResult program (Succeeds expectedResult) (SuccessResult actualResult) =
  case compareValues actualResult expectedResult of
    Just mismatch -> do
      actualf <-
        io $ writeOutFile program "actual" $
        unlines $ map pretty actualResult
      expectedf <-
        io $ writeOutFile program "expected" $
        unlines $ map pretty expectedResult
      throwError $ actualf ++ " and " ++ expectedf ++ " do not match:\n" ++ show mismatch
    Nothing ->
      return ()
compareResult _ (RunTimeFailure expectedError) (ErrorResult _ actualError) =
  checkError expectedError actualError
compareResult _ (Succeeds _) (ErrorResult _ err) =
  throwError $ "Program failed with error:\n  " ++ err
compareResult _ (RunTimeFailure f) (SuccessResult _) =
  throwError $ "Program succeeded, but expected failure:\n  " ++ show f

writeOutFile :: FilePath -> String -> String -> IO FilePath
writeOutFile base ext content =
  attempt (0::Int)
  where template = base `replaceExtension` ext
        attempt i = do
          let filename = template ++ "-" ++ show i
          exists <- doesFileExist filename
          if exists
            then attempt $ i+1
            else do writeFile filename content
                    return filename

data Mismatch = PrimValueMismatch Int PrimValue PrimValue
              | ArrayLengthMismatch Int Int Int
              | TypeMismatch Int Type Type
              | ValueCountMismatch Int Int

instance Show Mismatch where
  show (PrimValueMismatch i got expected) =
    explainMismatch i "" got expected
  show (ArrayLengthMismatch i got expected) =
    explainMismatch i "array of length" got expected
  show (TypeMismatch i got expected) =
    explainMismatch i "value of type" got expected
  show (ValueCountMismatch got expected) =
    "Expected " ++ show expected ++ " values, got " ++ show got

explainMismatch :: Pretty a => Int -> String -> a -> a -> String
explainMismatch i what expected got =
  "Value " ++ show i ++ " expected " ++ what ++ pretty expected ++ ", got " ++ pretty got

compareValues :: [Value] -> [Value] -> Maybe Mismatch
compareValues vs1 vs2
  | n /= m = Just $ ValueCountMismatch n m
  | otherwise = case sequence $ zipWith3 compareValue [0..] vs1 vs2 of
    Just (e:_) -> Just e
    _          -> Nothing
  where n = length vs1
        m = length vs2

compareValue :: Int -> Value -> Value -> Maybe Mismatch
compareValue i (PrimVal bv1) (PrimVal bv2)
  | comparePrimValue minTolerance bv1 bv2 = Nothing
  | otherwise = Just $ PrimValueMismatch i bv1 bv2
compareValue i (ArrayVal vs1 _ _) (ArrayVal vs2 _ _)
  | A.bounds vs1 == A.bounds vs2 =
      uncurry (PrimValueMismatch i) <$>
        find (not . uncurry (comparePrimValue tol)) (zip (A.elems vs1) (A.elems vs2))
  | otherwise =
      Just $ ArrayLengthMismatch i (snd $ A.bounds vs1) (snd $ A.bounds vs2)
  where tol = tolerance vs2
compareValue i v1 v2 =
  Just $ TypeMismatch i (valueType v1) (valueType v2)

comparePrimValue :: Double -> PrimValue -> PrimValue -> Bool
comparePrimValue tol (FloatValue (Float32Value x)) (FloatValue (Float32Value y)) =
  compareFractional tol x y
comparePrimValue tol  (FloatValue (Float64Value x)) (FloatValue (Float64Value y)) =
  compareFractional tol x y
comparePrimValue tol  (FloatValue (Float64Value x)) (FloatValue (Float32Value y)) =
  compareFractional tol x (floatToDouble y)
comparePrimValue tol  (FloatValue (Float32Value x)) (FloatValue (Float64Value y)) =
  compareFractional tol (floatToDouble x) y
comparePrimValue _ x y =
  x == y

compareFractional :: (Ord num, Fractional num, Real tol) =>
                     tol -> num -> num -> Bool
compareFractional tol x y =
  diff < fromRational (toRational tol)
  where diff = abs $ x - y

minTolerance :: Fractional a => a
minTolerance = 0.002 -- 0.2%

tolerance :: A.Array Int PrimValue -> Double
tolerance = foldl' tolerance' minTolerance
  where tolerance' t (FloatValue (Float32Value v)) = max t $ 0.001 * floatToDouble v
        tolerance' t (FloatValue (Float64Value v)) = max t $ 0.001 * v
        tolerance' t _                             = t

floatToDouble :: Float -> Double
floatToDouble x =
  let (m,n) = decodeFloat x
  in encodeFloat m n

---
--- Test manager
---

catching :: IO TestResult -> IO TestResult
catching m = m `catch` save
  where save :: SomeException -> IO TestResult
        save e = return $ Failure $ show e

doTest :: TestCase -> IO TestResult
doTest = catching . runTestM . runTestCase

makeTestCase :: ProgConfig -> TestMode -> FilePath -> IO TestCase
makeTestCase progs mode file = do
  spec <- applyMode mode <$> testSpecFromFile file
  return $ TestCase file spec progs

applyMode :: TestMode -> ProgramTest -> ProgramTest
applyMode mode test =
  test { testAction = applyModeToAction mode $ testAction test }

applyModeToAction :: TestMode -> TestAction -> TestAction
applyModeToAction _ a@CompileTimeFailure{} =
  a
applyModeToAction OnlyTypeCheck (RunCases _) =
  RunCases []
applyModeToAction mode (RunCases cases) =
  RunCases $ map (applyModeToCase mode) cases

applyModeToCase :: TestMode -> TestRun -> TestRun
applyModeToCase OnlyInterpret run =
  run { runMode = InterpretedOnly }
applyModeToCase OnlyCompile run =
  run { runMode = CompiledOnly }
applyModeToCase _ run =
  run

runTest :: MVar TestCase -> MVar (TestCase, TestResult) -> IO ()
runTest testmvar resmvar = forever $ do
  test <- takeMVar testmvar
  res <- doTest test
  putMVar resmvar (test, res)

excludedTest :: TestConfig -> TestCase -> Bool
excludedTest config =
  any (`elem` configExclude config) . testTags . testCaseTest

clearLine :: IO ()
clearLine = putStr "\27[2K"

reportInteractive :: String -> Int -> Int -> Int -> IO ()
reportInteractive first failed passed remaining = do
  clearLine
  putStr $
    "\rWaiting for " ++ first ++ " (" ++
    show failed ++ " failed, " ++
    show passed ++ " passed, " ++
    show remaining ++ " to go.)\r"
  hFlush stdout

reportText :: String -> Int -> Int -> Int -> IO ()
reportText first failed passed remaining =
  putStr $ "Waiting for " ++ first ++ " (" ++
         show failed ++ " failed, " ++
         show passed ++ " passed, " ++
         show remaining ++ " to go.)\n"

runTests :: TestConfig -> [FilePath] -> IO ()
runTests config files = do
  let mode = configTestMode config
  testmvar <- newEmptyMVar
  resmvar <- newEmptyMVar
  concurrency <- getNumCapabilities
  replicateM_ concurrency $ forkIO $ runTest testmvar resmvar
  all_tests <- mapM (makeTestCase (configPrograms config) mode) files
  let (excluded, included) = partition (excludedTest config) all_tests
  _ <- forkIO $ mapM_ (putMVar testmvar) included
  isTTY <- hIsTerminalDevice stdout

  let report = if isTTY then reportInteractive else reportText
      clear  = if isTTY then clearLine else putStr "\n"
      getResults remaining failed passed =
        case S.toList remaining of
          []      -> clear >> return (failed, passed)
          first:_ -> do
            report (testCaseProgram first) failed passed $ S.size remaining
            (test, res) <- takeMVar resmvar
            let next = getResults $ test `S.delete` remaining
            case res of
              Success -> next failed (passed+1)
              Failure s -> do clear
                              putStrLn (testCaseProgram test ++ ":\n" ++ s)
                              next (failed+1) passed

  (failed, passed) <- getResults (S.fromList included) 0 0
  let excluded_str = if null excluded
                     then ""
                     else " (" ++ show (length excluded) ++ " excluded)"
  putStrLn $ show failed ++ " failed, " ++ show passed ++ " passed" ++ excluded_str ++ "."
  exitWith $ case failed of 0 -> ExitSuccess
                            _ -> ExitFailure 1

---
--- Configuration and command line parsing
---

data TestConfig = TestConfig
                  { configTestMode :: TestMode
                  , configPrograms :: ProgConfig
                  , configExclude :: [T.Text]
                  }

defaultConfig :: TestConfig
defaultConfig = TestConfig { configTestMode = Everything
                           , configExclude = []
                           , configPrograms =
                             ProgConfig
                             { configCompiler = Left "futhark-c"
                             , configInterpreter = Left "futharki"
                             , configTypeChecker = Left "futhark"
                             }
                           }

data ProgConfig = ProgConfig
                  { configCompiler :: Either FilePath [FilePath]
                  , configInterpreter :: Either FilePath [FilePath]
                  , configTypeChecker :: Either FilePath [FilePath]
                  }
                  deriving (Show)

changeProgConfig :: (ProgConfig -> ProgConfig) -> TestConfig -> TestConfig
changeProgConfig f config = config { configPrograms = f $ configPrograms config }

configCompilers :: ProgConfig -> [FilePath]
configCompilers = either pure id . configCompiler

configInterpreters :: ProgConfig -> [FilePath]
configInterpreters = either pure id . configInterpreter

configTypeCheckers :: ProgConfig -> [FilePath]
configTypeCheckers = either pure id . configTypeChecker

addCompiler :: FilePath -> ProgConfig -> ProgConfig
addCompiler compiler config = case configCompiler config of
  Left _ -> config { configCompiler = Right [compiler] }
  Right existing -> config { configCompiler = Right $ compiler : existing }

addInterpreter :: FilePath -> ProgConfig -> ProgConfig
addInterpreter interpreter config = case configInterpreter config of
  Left _ -> config { configInterpreter = Right [interpreter] }
  Right existing -> config { configInterpreter = Right $ interpreter : existing }

addTypeChecker :: FilePath -> ProgConfig -> ProgConfig
addTypeChecker typeChecker config = case configTypeChecker config of
  Left _ -> config { configTypeChecker = Right [typeChecker] }
  Right existing -> config { configTypeChecker = Right $ typeChecker : existing }

data TestMode = OnlyTypeCheck
              | OnlyCompile
              | OnlyInterpret
              | Everything

commandLineOptions :: [FunOptDescr TestConfig]
commandLineOptions = [
    Option "t" ["only-typecheck"]
    (NoArg $ Right $ \config -> config { configTestMode = OnlyTypeCheck })
    "Only perform type-checking"
  , Option "i" ["only-interpret"]
    (NoArg $ Right $ \config -> config { configTestMode = OnlyInterpret })
    "Only interpret"
  , Option "c" ["only-compile"]
    (NoArg $ Right $ \config -> config { configTestMode = OnlyCompile })
    "Only run compiled code"

  , Option [] ["typechecker"]
    (ReqArg (Right . changeProgConfig . addTypeChecker)
     "PROGRAM")
    "What to run for type-checking (defaults to 'futhark')."
  , Option [] ["compiler"]
    (ReqArg (Right . changeProgConfig . addCompiler)
     "PROGRAM")
    "What to run for code generation (defaults to 'futhark-c')."
  , Option [] ["interpreter"]
    (ReqArg (Right . changeProgConfig . addInterpreter)
     "PROGRAM")
    "What to run for interpretation (defaults to 'futharki')."
  , Option [] ["exclude"]
    (ReqArg (\tag ->
               Right $ \config ->
               config { configExclude = T.pack tag : configExclude config })
     "TAG")
    "Exclude test programs that define this tag."
  ]

main :: IO ()
main = mainWithOptions defaultConfig commandLineOptions $ \progs config ->
  Just $ runTests config progs
