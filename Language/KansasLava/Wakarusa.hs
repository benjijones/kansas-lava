{-# LANGUAGE GADTs, KindSignatures, RankNTypes, ScopedTypeVariables, DoRec, TypeFamilies, FlexibleContexts #-}

module Language.KansasLava.Wakarusa 
        ( STMT(..)
        , LABEL(..)
        , REG(..)
        , EXPR(..)
        , VAR(..)
        , compileToFabric
        , ReadableAckBox
        , connectReadableAckBox
        , WritableAckBox
        , connectWritableAckBox
        , takeAckBox
        , putAckBox
        ) where

import Language.KansasLava.Wakarusa.AST
import Language.KansasLava.Wakarusa.Monad

import Language.KansasLava.Signal
import Language.KansasLava.Fabric
import Language.KansasLava.Rep
import Language.KansasLava.Utils
import Language.KansasLava.Protocols.Enabled

import Data.Sized.Ix

import Control.Monad.Fix
import Data.Map as Map
import Control.Monad.State
import Control.Monad.Reader

import Debug.Trace

import qualified Data.Set as Set
import Data.Set (Set)

------------------------------------------------------------------------------

compileToFabric :: STMT [LABEL] -> Fabric () 
compileToFabric prog = do 
        let res0 = runStateT (compWakarusa prog)
        let res1 = res0 $ WakarusaState 
                    { ws_uniq = 0 
                    , ws_label = Nothing
                    , ws_regs = Map.empty
                    , ws_assignments = Map.empty
                    , ws_inputs = Map.empty
                    , ws_pc = 0
                    , ws_labels = Map.empty
                    , ws_pcs = []
                    }
        let res2 = runReaderT res1

        let

        rec res3 <- res2 $ WakarusaEnv 
                    { we_pred  = Nothing
                    , we_writes = ws_assignments st
                    , we_reads  = ws_inputs st `Map.union`
                                  (placeRegisters (ws_regs st) $ ws_assignments st)
                    , we_pcs = generatePredicates (ws_labels st) (ws_pcs st) (ws_pc st) labels
--                    Map.mapWithKey (placePC labels) $ ws_pcs1
                    } 
            let (labels,st) = res3
--                ws_pcs1 = Map.union (ws_pcs st)
--                                    (Map.fromList [(lab,disabledS) | lab <- labels])

        return ()


generateThreadIds 
        :: Map LABEL PC                         -- ^ label table
        -> [(PC,Maybe (Seq Bool),LABEL)]        -- ^ jumps
        -> PC                                   -- ^ last PC number + 1
        -> [LABEL]                              -- ^ thread starts
        -> Map PC Int                   -- Which thread am I powered by
generateThreadIds label_table jumps pc threads  = trace (show result) result
   where
        links :: Map PC (Set PC)
        links = Map.fromListWith (Set.union) $
                [ (src_pc, Set.singleton dest_pc)
                | (src_pc,_,dest_label) <- jumps
                , let Just dest_pc = Map.lookup dest_label label_table
                ] ++
                [ (n,Set.singleton $ n+1)
                | n <- [0..(pc-2)]
                        -- not pc-1, becasuse the last instruction 
                        -- can not jump to after the last instruction
                , (n `notElem` unconditional_jumps)
                ]


        -- PC values that have unconditional jumps (does not matter where to)
        unconditional_jumps =
                [ src_pc
                | (src_pc,Nothing,_) <- jumps
                ] 

        result :: Map PC Int
        result =  Map.fromList
                [ (a,pid)
                | (lab,pid) <- zip threads [0..]
                , let Just fst_pc = Map.lookup lab label_table
                , a <- Set.toList $ transitiveClosure (\ a -> Map.findWithDefault (Set.empty) a links) fst_pc
                ]

generatePredicates 
        :: Map LABEL PC                         -- ^ label table
        -> [(PC,Maybe (Seq Bool),LABEL)]        -- ^ jumps
        -> PC                                   -- ^ last PC number + 1
        -> [LABEL]                              -- ^ thread starts
        -> Map PC (Seq Bool)                    -- ^ table of predicates
                                                --   for each row of instructions
generatePredicates label_table jumps pc threads = result
  where
        threadIds = generateThreadIds label_table jumps pc threads

        result = mapWithKey (\ k tid -> pureS k .==. pcs !! tid) threadIds

        -- a list of thread PC's
        pcs :: [Seq PC]
        pcs = [ let pc_reg = register first_pc
                                        -- we are checking the match with PC twice?
                             $ cASE [ (case opt_pred of
                                          Nothing -> this_inst
                                          Just p -> this_inst .&&. p, pureS dest_pc)

                                    | (pc_src,opt_pred,dest_label) <- jumps
                                    , let Just dest_pc = Map.lookup dest_label label_table
                                    , let this_inst = Map.findWithDefault
                                                                (error $ "this_inst" ++ show (pc_src,fmap (const ()) result))
                                                                pc_src
                                                                result
                                    ]
                                    (pc_reg + 1)
                  in pc_reg
                | th_label <- threads
                , let Just first_pc = Map.lookup th_label label_table
                ]
{-
placePC :: [LABEL] -> LABEL -> Seq (Enabled (Enabled PC)) -> Seq (Enabled PC)
placePC starts lab inp = out
   where
           out = registerEnabled initial 
               $ cASE [ (isEnabled inp, inp)
                      , (isEnabled out, enabledS $ enabledS $ (enabledVal out + 1))
                      ] disabledS

           initial :: Enabled PC
           initial = if lab `elem` starts then Just 0 else Nothing
-}

placeRegisters :: Map Uniq (Pad -> Pad) -> Map Uniq Pad -> Map Uniq Pad
placeRegisters regMap = Map.mapWithKey (\ k p -> 
        case Map.lookup k regMap of
          Nothing -> error $ "can not find register for " ++ show k
          Just f  -> f p)
 

------------------------------------------------------------------------------

compWakarusa :: STMT a -> WakarusaComp a
compWakarusa (RETURN a) = return a
compWakarusa (BIND m1 k1) = do
        r1 <- compWakarusa m1
        compWakarusa (k1 r1)
compWakarusa (MFIX fn) = mfix (compWakarusa . fn)

compWakarusa (REGISTER def) = do
        uq <- getUniq
        let reg = R uq
        -- add the register to the table
        addRegister reg def
        return (VAR $ toVAR $ reg)

compWakarusa (OUTPUT connect) = do
        uq  <- getUniq   -- the uniq name of this output
        wt <- getRegWrite uq
        addToFabric (connect wt)
        return $ R uq
compWakarusa (INPUT fab) = do
        inp <- addToFabric fab
        -- Why not just return the inp?
        --  * Can not use OP0 (requires combinatorial value)
        --  * We *could* add a new constructor, IN (say)
        --  * but by using a REG, we are recording the
        --    use of an INPUT that changes over time,
        --    in the same way as registers are accesssed.
        u <- getUniq
        let reg = R u
        addInput reg inp
        return (REG reg)
compWakarusa (LABEL) = do
        -- get the number of the thread
        uq <- getUniq
        let lab = L uq
        newLabel lab
        return $ lab
compWakarusa e@(_ := _) = compWakarusaSeq e
compWakarusa e@(GOTO _) = compWakarusaSeq e
compWakarusa e@(_ :? _) = compWakarusaSeq e
compWakarusa e@(PAR _)  = compWakarusaPar e
compWakarusa _ = error "compWakarusa _"


------------------------------------------------------------------------------

compWakarusaSeq :: STMT () -> WakarusaComp ()
compWakarusaSeq e = do
        _ <- compWakarusaStmt e
        incPC
        return ()

compWakarusaPar :: STMT () -> WakarusaComp ()
compWakarusaPar e = do
        _ <- compWakarusaPar' e
        incPC
        return ()        
  where
          -- can be replaced with compWakarusaStmt?
   compWakarusaPar' (PAR es) = do
        mores <- mapM compWakarusaPar' es
        return $ and mores
   compWakarusaPar' o = compWakarusaStmt o
        

------------------------------------------------------------------------------

compWakarusaStmt :: STMT () -> WakarusaComp Bool
compWakarusaStmt (R n := expr) = do
        exprCode <- compWakarusaExpr expr
        addAssignment (R n) exprCode
        return True
compWakarusaStmt (GOTO lab) = do
        recordJump lab
        return False
compWakarusaStmt (e1 :? m) = do
        predCode <- compWakarusaExpr e1
        _ <- setPred predCode $ compWakarusaStmt m
        return True  -- if predicated, be pesamistic, and assume no jump was taken
compWakarusaStmt (PAR es) = do
        mores <- mapM compWakarusaStmt es
        return $ and mores        
compWakarusaStmt (RETURN ()) = return False
compWakarusaStmt (BIND LABEL k1) = do -- getting hacky; breaks monad laws
        r1 <- compWakarusa LABEL
        compWakarusaStmt (k1 r1)
compWakarusaStmt s = error $ "compWakarusaStmt : unsupport operation construct : \n" ++ show s

------------------------------------------------------------------------------

compWakarusaExpr :: (Rep a) => EXPR a -> WakarusaComp (Seq a)
compWakarusaExpr (REG (R r)) = getRegRead r
compWakarusaExpr (OP0 lit) = do
        return $ lit
compWakarusaExpr (OP1 f e) = do
        c <- compWakarusaExpr e
        return $ f c
compWakarusaExpr (OP2 f e1 e2) = do
        c1 <- compWakarusaExpr e1
        c2 <- compWakarusaExpr e2
        return $ f c1 c2

------------------------------------------------------------------------------

-- add assignment in the context of the PC
addAssignment :: (Rep a) => REG a -> Seq a -> WakarusaComp ()
addAssignment reg expr = do
        p <- getPred
        registerAction reg p expr

------------------------------------------------------------------------------

-- technically, we could just look at the frontier each time.

transitiveClosure :: (Ord a) => (a -> Set a) -> a -> Set a
transitiveClosure f a = fixpoint $ iterate step (Set.singleton a)
   where
           fixpoint (x0:x1:_) | x0 == x1 = x0
           fixpoint (_:xs)    = fixpoint xs
           fixpoint _         = error "reached end of infinite list"
           
           step x = x `Set.union` Set.unions (fmap f (Set.toList x))

--------------------------------------------------------------------------------


data ReadableAckBox a = ReadableAckBox (EXPR (Enabled a)) (REG ())

connectReadableAckBox
        :: forall a . (Rep a, Size (ADD (W a) X1), Show a)
        => String -> String -> STMT (ReadableAckBox a)
connectReadableAckBox inpName ackName = do
        i :: EXPR (Maybe a)   <- INPUT  (inStdLogicVector inpName)
        o :: REG ()           <- OUTPUT (outStdLogic ackName . isEnabled)
        return $ ReadableAckBox i o
                       
takeAckBox :: Rep a => ReadableAckBox a -> (EXPR a -> STMT ()) -> STMT ()
takeAckBox (ReadableAckBox iA oA) cont = do
        self <- LABEL
        do PAR [ OP1 (bitNot . isEnabled) iA :? GOTO self
               , OP1 (         isEnabled) iA :? do
                       PAR [ oA := OP0 (pureS ())
                           , cont (OP1 enabledVal iA)
                           ]
               ]

data WritableAckBox a = WritableAckBox (REG a) (EXPR Bool) 

connectWritableAckBox
        :: forall a . (Rep a, Size (ADD (W a) X1), Show a)
        => String -> String -> STMT (WritableAckBox a)
connectWritableAckBox outName ackName = do
        iB :: EXPR Bool <- INPUT  (inStdLogic ackName)
        oB :: REG a     <- OUTPUT (outStdLogicVector outName)
        return $ WritableAckBox oB iB

putAckBox :: Rep a => WritableAckBox a -> EXPR a -> STMT () -> STMT ()
putAckBox (WritableAckBox oB iB) val cont = do
        self <- LABEL 
        do PAR [ oB := val
               , OP1 (bitNot) iB :? GOTO self
               , iB              :? cont
               ]
