{-# LANGUAGE ScopedTypeVariables, RankNTypes, TypeFamilies, FlexibleContexts, ExistentialQuantification, DataKinds #-}

module Protocols where

import Language.KansasLava
import Language.KansasLava.Test

import Data.Sized.Fin
import Data.Sized.Unsigned
import Data.Sized.Matrix (matrix, Matrix)

import Data.Array.IArray
import GHC.TypeLits

--import qualified Data.Sized.Matrix as M
--import Debug.Trace

type instance (5 + 5) = 10
type instance (3 * 5) = 15

tests :: TestSeq -> IO ()
tests test = do
        return ()
{-
  This needs re-written

        -- testing Streams

        let fifoTest :: forall w . (Rep w, Eq w, Show w, SingI (W w))
		      => String
		      -> Patch (Seq (Enabled w)) (Seq (Enabled w)) (Seq Ack) (Seq Ack) -> StreamTest w w
            fifoTest n f = StreamTest
                        { theStream = f
                        , correctnessCondition = \ ins outs -> -- trace (show ("cc",length ins,length outs)) $
                                case () of
                                  () | outs /= take (length outs) ins -> return "in/out differences"
                                  () | length outs < fromIntegral count
     								      -> return ("to few transfers: " ++ show (length outs))
                                     | otherwise -> Nothing

	    		, theStreamTestCount  = count
	    		, theStreamTestCycles = 10000
                        , theStreamName = n
                        }
	   	where
			count = 100

{-
	let bridge' :: forall w . (Rep w,Eq w, Show w, Size (W w))
		      	=> (Seq (Enabled w), Seq Full) -> (Seq Ack, Seq (Enabled w))
	    bridge' =  bridge `connect` shallowFIFO `connect` bridge
-}

	testStream test "U5"   (fifoTest "emptyP" emptyP :: StreamTest U5 U5)
	testStream test "Bool" (fifoTest "emptyP" emptyP :: StreamTest Bool Bool)
	testStream test "U5"   (fifoTest "fifo1" fifo1 :: StreamTest U5 U5)
	testStream test "Bool" (fifoTest "fifo1" fifo1 :: StreamTest Bool Bool)
	testStream test "U5"   (fifoTest "fifo2" fifo2 :: StreamTest U5 U5)
	testStream test "Bool" (fifoTest "fifo2" fifo2 :: StreamTest Bool Bool)


	-- This tests dupP and zipP
        let patchTest1 :: forall w . (Rep w,Eq w, Show w, SingI (W w), Num w)
		      => StreamTest w (w,w)
            patchTest1 = StreamTest
                        { theStream = dupP $$ fstP (forwardP $ mapEnabled (+1)) $$ zipP
                        , correctnessCondition = \ ins outs -> -- trace (show ("cc",length ins,length outs)) $
--				trace (show (ins,outs)) $
                                case () of
				  () | length outs /= length ins -> return "in/out differences"
				     | any (\ (x,y) -> x - 1 /= y) outs -> return "bad result value"
				     | ins /= map snd outs -> return "result not as expected"
                                     | otherwise -> Nothing

	    		, theStreamTestCount  = count
	    		, theStreamTestCycles = 10000
                        , theStreamName = "dupP-zipP"
                        }
	   	where
			count = 100

	testStream test "U5" (patchTest1 :: StreamTest U5 (U5,U5))


	-- This tests matrixDupP and matrixZipP
        let patchTest2 :: forall w . (Rep w,Eq w, Show w, SingI (W w), Num w)
		      => StreamTest w (Matrix (Fin 3) w)
            patchTest2 = StreamTest
                        { theStream = matrixDupP $$ matrixStackP (matrix [
								forwardP $ mapEnabled (+0),
								forwardP $ mapEnabled (+1),
								forwardP $ mapEnabled (+2)]
								) $$ matrixZipP
                        , correctnessCondition = \ ins outs -> -- trace (show ("cc",length ins,length outs)) $
--				trace (show (ins,outs)) $
                                case () of
				  () | length outs /= length ins -> return "in/out differences"
				     | any (\ m -> m ! 0 /= (m ! 1) - 1) outs -> return "bad result value 0,1"
				     | any (\ m -> m ! 0 /= (m ! 2) - 2) outs -> return $ "bad result value 0,2"
				     | ins /= map (! 0) outs -> return "result not as expected"
                                     | otherwise -> Nothing

	    		, theStreamTestCount  = count
	    		, theStreamTestCycles = 10000
                        , theStreamName = "matrixDupP-matrixZipP"
                        }
	   	where
			count = 100

	testStream test "U5" (patchTest2 :: StreamTest U5 (Matrix (Fin 3) U5))

	-- This tests muxP (and matrixMuxP)
        let patchTest3 :: forall w . (Rep w,Eq w, Show w, SingI (W w), Num w, w ~ U5)
		      => StreamTest w w
            patchTest3 = StreamTest
                        { theStream =
				fifo1 $$
				dupP $$
				stackP (forwardP (mapEnabled (*2)) $$ fifo1)
				      (forwardP (mapEnabled (*3)) $$ fifo1) $$
				openP $$
				fstP (cycleP (matrix [True,False] :: Matrix (Fin 2) Bool) $$ fifo1) $$
				muxP


                        , correctnessCondition = \ ins outs -> -- trace (show ("cc",length ins,length outs)) $
--				trace (show (ins,outs)) $
                                case () of
				  () | length outs /= length ins * 2 -> return "in/out size issues"
			             | outs /= concat [ [n * 2,n * 3] | n <- ins ]
								     -> return "value out distored"
                                     | otherwise -> Nothing

	    		, theStreamTestCount  = count
	    		, theStreamTestCycles = 10000
                        , theStreamName = "muxP"
                        }
	   	where
			count = 100

	testStream test "U5" (patchTest3 :: StreamTest U5 U5)

	-- This tests deMuxP (and matrixDeMuxP), and zipP
        let patchTest4 :: forall w . (Rep w,Eq w, Show w, SingI (W w), Num w, w ~ U5)
		      => StreamTest w (w,w)
            patchTest4 = StreamTest
                        { theStream =
				openP $$
				fstP (cycleP (matrix [True,False] :: Matrix (Fin 2) Bool) $$ fifo1) $$
				deMuxP $$
				stackP (fifo1) (fifo1) $$
				zipP
                        , correctnessCondition = \ ins outs -> -- trace (show ("cc",length ins,length outs)) $
--				trace (show (ins,outs)) $
                                case () of
				  () | length outs /= length ins `div` 2 -> return "in/out size issues"
			             | concat [ [a,b] | (a,b) <- outs ] /= ins
								     -> return "value out distored"
                                     | otherwise -> Nothing

	    		, theStreamTestCount  = count
	    		, theStreamTestCycles = 10000
                        , theStreamName = "deMuxP-zipP"
                        }
	   	where
			count = 100

	testStream test "U5" (patchTest4 :: StreamTest U5 (U5,U5))
	return ()
-}