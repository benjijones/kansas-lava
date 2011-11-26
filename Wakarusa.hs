{-# LANGUAGE GADTs, KindSignatures, RankNTypes, ScopedTypeVariables, DoRec, TypeFamilies, FlexibleContexts, CPP #-}
import Language.KansasLava hiding ((&))

import Language.KansasLava.Universal
import Language.KansasLava.Fabric
import Data.Sized.Unsigned
import Data.Sized.Ix

import Control.Monad.Fix
import Data.Set as Set
import Data.Map as Map
import Data.Maybe 


------------------------------------------------------------------------

prog1 :: STMT [LABEL]
prog1 = do
        o0 :: REG Int   <- OUTPUT (outStdLogicVector "o0" . delayEnabled)
        loop <- LABEL
        o0  := 99
        GOTO loop
        return [loop]

fab1 = compileToFabric prog1

run1 :: Seq Int
run1 = runFabricWithDriver fab1 $ do
                inStdLogicVector "o0" :: Fabric (Seq Int)

-- 2nd output should be 9 | ...
prog2 :: STMT [LABEL]
prog2 = do
        o0 :: REG Int   <- OUTPUT (outStdLogicVector "o0" . delayEnabled)
        VAR v0  :: VAR Int           <- REGISTER $ Just 9
        loop <- LABEL
        o0 := v0
        GOTO loop
        return [loop]

fab2 = compileToFabric prog2

run2 :: Seq Int
run2 = runFabricWithDriver fab2 $ do
                inStdLogicVector "o0" :: Fabric (Seq Int)

prog3 :: STMT [LABEL]
prog3 = do
        o0     :: REG Int   <- OUTPUT (outStdLogicVector "o0" . delayEnabled . probeS "o0")
        VAR v0 :: VAR Int   <- REGISTER $ Just 9
        loop <- LABEL
        v0 := 10
        o0 := v0
        GOTO loop
        return [loop]

fab3 = compileToFabric prog3

run3 :: Seq Int
run3 = runFabricWithDriver fab3 $ do
                inStdLogicVector "o0" :: Fabric (Seq Int)


prog4 :: STMT [LABEL]
prog4 = do
        o0     :: REG Int   <- OUTPUT (outStdLogicVector "o0" . delayEnabled . probeS "o0")
        VAR v0 :: VAR Int   <- REGISTER $ Just 0
        loop <- LABEL
        (v0 := v0 + 1) 
          ||| (o0 := v0) 
          ||| GOTO loop
        return [loop]

(&) m1 m2 = m1 >> m2

fab4 = compileToFabric prog4

run4 :: Seq Int
run4 = runFabricWithDriver fab4 $ do
                inStdLogicVector "o0" :: Fabric (Seq Int)

prog5 :: STMT [LABEL]
prog5 = do
        o0     :: REG Int   <- OUTPUT (outStdLogicVector "o0" . delayEnabled . probeS "o0")
        VAR v0 :: VAR Int   <- REGISTER $ Just 0
        loop <- LABEL
        (v0 := v0 + 1) 
        (o0 := v0) 
        GOTO loop
        return [loop]

fab5 = compileToFabric prog5

run5 :: Seq Int
run5 = runFabricWithDriver fab5 $ do
                inStdLogicVector "o0" :: Fabric (Seq Int)


prog6 :: STMT [LABEL]
prog6 = do
        wAckBox@(WritableAckBox oB iB) :: WritableAckBox Int <- connectWritableAckBox "oB" "iB"
        VAR v0 :: VAR Int   <- REGISTER $ Just 0
        loop <- LABEL
        oB := v0
--        putAckBox wAckBox v0 (return ())
                ||| GOTO loop
                ||| (v0 := v0 + 1) 
--                ||| GOTO loop
        return [loop]

fab6 = compileToFabric prog6

run6 :: Patch () (Seq (Enabled Int))
              () (Seq Ack)
run6 ~(_,outAck) = runFabricWithDriver fab6 $ do
                outStdLogic "iB" outAck
                out <- inStdLogicVector "oB"
                return ((),out)

data FOO = FOO Int deriving Show

foo = FOO

#define FOO foo __LINE__

fooy = print (FOO)

{-             
progX :: STMT [LABEL]
progX = do
--        rAckBox :: ReadableAckBox Int <- connectReadableAckBox "iA" "oA"
--        wAckBox :: WritableAckBox Int <- connectWritableAckBox "oB" "iB"

        s0 :: REG Int   <- OUTPUT (outStdLogicVector "XX")


        VAR v0  :: VAR Int           <- REGISTER $ Just 0
--        ARR a0  :: ARR X8 Int        <- ARRAY

        loop <- LABEL
        v0 := v0 + 1
        s0 := v0
--        takeAckBox rAckBox (v0 :=)
--        STEP
--        putAckBox wAckBox v0 (return ()) 
--        STEP
        GOTO loop


{-
        ST a0 0 99
        a0 := OP2 pack 0 99
        a0 := WT 0 99

        v0 := LD a0 0
-}


        return [loop] 

{-
fab0 = compileToFabric prog1
fab1 ::        (Seq (Enabled Int), Seq Ack)
     -> Fabric (Seq Ack, Seq (Enabled Int))
fab1 ~(inp,outAck) = do
        outStdLogicVector "iA" inp
        inAck <- inStdLogic "oA"
        outStdLogic "iB" outAck
        out <- inStdLogicVector "oB"
        return (inAck,out)

test args = runFabricWithDriver fab0 (fab1 args)
xs = take 1000 $ runAckBoxP (shallowAckBoxBridge (cycle [1,2,3,0],cycle [0,2,1]) $$ test) [1..1000]
-}

--t = fromJust (head [ fromUni p |  ("o0",p) <- snd (runFabric fab [("i0",toUni (toS [0..] :: Seq Int))]) ]) :: (Seq (Enabled Int))

          
          
{-
--        bar <- LABEL
--        oB := OP0 (pureS Nothing)
--        GOTO bar

{-        
        rec loop <- thread $ do
                PAR [ -- v0 := v0 + 1
                     o0 := i0
                    , GOTO loop
                    ]

-}
{-      

        rec loop <- thread $ do
                v0 := i0
--                v0 := v0 + 1
--                (OP1 (.==. 104) v0) :? do
                o0 := v0
                GOTO loop
-}
-}
-}          