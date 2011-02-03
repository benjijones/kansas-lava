{-# LANGUAGE ScopedTypeVariables, FlexibleContexts, TypeFamilies, UndecidableInstances, FlexibleInstances #-}

module Language.KansasLava.StdLogicVector where

import Data.Bits
import Control.Monad

import Data.Sized.Matrix as M
import Language.KansasLava.Types
import Language.KansasLava.Shallow
import Data.Sized.Arith
import Data.Sized.Unsigned as U
import Data.Sized.Signed as S

import Data.Word
import Data.Char as Char

-- | StdLogicVector is a bit accurate, sized general representation of bit vectors.

data StdLogicVector a = StdLogicVector (Matrix a (WireVal Bool))
	deriving (Eq,Ord)


undefinedStdLogicVector :: (Size x) => StdLogicVector x
undefinedStdLogicVector = StdLogicVector $ forAll $ \ _ -> WireUnknown


-- NOTE: This used to be reversed
instance (Size a) => Show (StdLogicVector a) where
	show (StdLogicVector m) = show $ RepValue $ M.toList m

-- This is needed for Bits to work.
instance (Size ix) => Num (StdLogicVector ix) where
	(+) = error "(+) is undefined for StdLogicVector"
	(-) = error "(-) is undefined for StdLogicVector"
	(*) = error "(*) is undefined for StdLogicVector"
	abs = error "abs is undefined for StdLogicVector"
	signum = error "signum is undefined for StdLogicVector"
	fromInteger n = StdLogicVector $ fmap WireVal $ matrix $ take (size (error "witness" :: ix)) $ map odd $ iterate (`div` 2) n

instance (Integral ix, Size ix) => Bits (StdLogicVector ix) where
	bitSize s = size (error "witness" :: ix)

	complement (StdLogicVector m) = StdLogicVector (fmap (liftM not) m)
	isSigned _ = False

	(StdLogicVector a) `xor` (StdLogicVector b) = StdLogicVector $ M.zipWith (liftM2 (/=)) a b
	(StdLogicVector a) .|. (StdLogicVector b) = StdLogicVector $ M.zipWith (liftM2 (||)) a b
	(StdLogicVector a) .&. (StdLogicVector b) = StdLogicVector $ M.zipWith (liftM2 (&&)) a b

	shiftL (StdLogicVector m) i = StdLogicVector $ forAll $ off
	  where
		mx = size (error "witness" :: ix)
		off ix | ix' >= mx || ix' < 0 = WireVal False
		       | otherwise            = m ! fromIntegral ix'
	            where
			ix' = fromIntegral ix - i
	shiftR (StdLogicVector m) i = StdLogicVector $ forAll $ off
	  where
		mx = size (error "witness" :: ix)
		off ix | ix' >= mx || ix' < 0 = WireVal False
		       | otherwise            = m ! fromIntegral ix'
	            where
			ix' = fromIntegral ix + i
 	rotate (StdLogicVector m) i = StdLogicVector $ forAll $ off
	  where
		mx = size (error "witness" :: ix)
		off ix | ix' >= mx || ix' < 0 = WireVal False
		       | otherwise            = m ! fromIntegral ix'
	            where
			ix' = fromIntegral ix - i
        testBit (StdLogicVector m) idx =  case m ! fromIntegral idx of
					     WireVal b -> b
					     _ -> error "testBit unknown bit"

-- AJG: this was reverseed m2 ++ m1, for some reason. Restored to m1 ++ m2

appendSLV :: (Size x, Size y, Size (ADD x y)) => StdLogicVector x -> StdLogicVector y -> StdLogicVector (ADD x y)
appendSLV (StdLogicVector m1) (StdLogicVector m2) = (StdLogicVector $ M.matrix (M.toList m1 ++ M.toList m2))

{-
splice :: (Integral inp, Integral res, Size high, Size low, Size res, Size inp, res ~ ADD (SUB high low) X1)
       => high -> low -> StdLogicVector inp -> StdLogicVector res
splice high low inp = StdLogicVector $ forAll $ \ ix -> inp' ! (fromIntegral ix)
  where
	StdLogicVector inp' = shiftR inp (size low)
-}

spliceSLV :: forall inp res . (Integral inp, Integral res, Size res, Size inp)
       => Int -> StdLogicVector inp -> StdLogicVector res
spliceSLV low v = coerceSLV $ shiftR v low

-- either take lower bits, or append zeros to upper bits.
coerceSLV :: forall a b . (Size a, Size b) => StdLogicVector a -> StdLogicVector b
coerceSLV (StdLogicVector m) = StdLogicVector
			  $ M.matrix
			  $ take (size (error "witness" :: b))
			  $ M.toList m ++ repeat (WireVal False)

-- TODO: Add Rep to the superclass list
-- Call something other than StdLogic,
-- HasWidth? for example.

class (Rep w, Integral (WIDTH w),Size (WIDTH w)) => StdLogic w where
  type WIDTH w

instance StdLogic Bool where
   type WIDTH Bool = X1

instance (Integral w, Size w) => StdLogic (U.Unsigned w) where
   type WIDTH (U.Unsigned w) = w

instance (Integral w, Size w) => StdLogic (S.Signed w) where
   type WIDTH (S.Signed w)  = w

instance (Integral w, Size w) => StdLogic (M.Matrix w Bool) where
   type WIDTH (M.Matrix w Bool)  = w

instance StdLogic X0 where
   type WIDTH X0 = X0

-- MESSSSYYYYY.
instance (Integral x, Size x, Integral (LOG (SUB (X1_ x) X1)), Size (LOG (SUB (X1_ x) X1)), StdLogic x) => StdLogic (X1_ x) where
   type WIDTH (X1_ x) = LOG (SUB (X1_ x) X1)

instance (Integral x, Size x, Integral (LOG (APP1 (ADD x N1))), Size (LOG (APP1 (ADD x N1))), StdLogic x) => StdLogic (X0_ x) where
   type WIDTH (X0_ x) = LOG (SUB (X0_ x) X1)

-- TODO: rename as to and from.
toSLV :: (Rep w, StdLogic w) => w -> StdLogicVector (WIDTH w)
toSLV v = case toRep (optX $ return v) of
		RepValue v -> StdLogicVector $ M.matrix $ v

fromSLV :: (Rep w, StdLogic w) => StdLogicVector (WIDTH w) -> Maybe w
fromSLV x@(StdLogicVector v) = unX (fromRep (RepValue (M.toList v)))

instance (Size ix) => Rep (StdLogicVector ix) where
        type W (StdLogicVector ix) = ix
	data X (StdLogicVector ix) = XSV (StdLogicVector ix)
	optX (Just b)	    = XSV b
	optX Nothing	    = XSV $ StdLogicVector $ forAll $ \ _ -> WireUnknown
	unX (XSV a)		    = return a
	repType x   	    = V (size (error "Wire/StdLogicVector" :: ix))
	toRep (XSV (StdLogicVector m)) = RepValue (M.toList m)
	fromRep (RepValue vs) = XSV $ StdLogicVector (M.matrix vs)
	showRep = showRepDefault


---------------------------------------------------------------------------
-- We use Bytes quite a bit for comms, which are a type of Word8.

type Byte = StdLogicVector X8

toByte :: Word8 -> Byte
toByte = fromIntegral

fromByte :: Byte -> Word8
fromByte b = case fromSLV b :: Maybe U8 of
	       Nothing -> error $ "fromByte: SLV was undefined: " ++ show b
	       Just v  -> fromIntegral v
