{-# LANGUAGE FlexibleContexts #-}
module Futhark.Pass.Simplify
  ( simplify
  , simplifySOACS
  , simplifySeq
  , simplifyKernels
  , simplifyKernelsMem
  , simplifySeqMem
  )
  where

import qualified Futhark.Representation.SOACS.Simplify as SOACS
import qualified Futhark.Representation.Kernels.Simplify as Kernels
import qualified Futhark.Representation.Seq as Seq
import qualified Futhark.Representation.KernelsMem as KernelsMem
import qualified Futhark.Representation.SeqMem as SeqMem

import Futhark.Pass
import Futhark.Representation.AST.Syntax

simplify :: (Prog lore -> PassM (Prog lore))
         -> Pass lore lore
simplify = Pass "simplify" "Perform simple enabling optimisations."

simplifySOACS :: Pass SOACS.SOACS SOACS.SOACS
simplifySOACS = simplify SOACS.simplifySOACS

simplifyKernels :: Pass Kernels.Kernels Kernels.Kernels
simplifyKernels = simplify Kernels.simplifyKernels

simplifySeq :: Pass Seq.Seq Seq.Seq
simplifySeq = simplify Seq.simplifyProg

simplifyKernelsMem :: Pass KernelsMem.KernelsMem KernelsMem.KernelsMem
simplifyKernelsMem = simplify KernelsMem.simplifyProg

simplifySeqMem :: Pass SeqMem.SeqMem SeqMem.SeqMem
simplifySeqMem = simplify SeqMem.simplifyProg
