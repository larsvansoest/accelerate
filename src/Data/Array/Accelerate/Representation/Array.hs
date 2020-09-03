{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE EmptyCase           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.Representation.Array
-- Copyright   : [2008..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.Representation.Array
  ( module Data.Array.Accelerate.Representation.Array, Buffer, Buffers )
  where

import Data.Array.Accelerate.Array.Buffer
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Representation.Elt
import Data.Array.Accelerate.Representation.Shape                   hiding ( zip )
import Data.Array.Accelerate.Representation.Type

import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import System.IO.Unsafe
import Text.Show                                                    ( showListWith )
import Prelude                                                      hiding ( (!!) )
import qualified Data.Vector.Unboxed                                as U


-- | Array data type, where the type arguments regard the representation
-- types of the shape and elements.
--
data Array sh e where
  Array :: sh                         -- extent of dimensions = shape
        -> Buffers e                  -- array payload
        -> Array sh e


-- | Segment descriptor (vector of segment lengths).
--
-- To represent nested one-dimensional arrays, we use a flat array of data
-- values in conjunction with a /segment descriptor/, which stores the lengths
-- of the subarrays.
--
type Segments = Vector

type Scalar = Array DIM0    -- ^ A singleton array with one element
type Vector = Array DIM1    -- ^ A one-dimensional array
type Matrix = Array DIM2    -- ^ A two-dimensional array

-- | Type witnesses shape and data layout of an array
--
data ArrayR a where
  ArrayR :: { arrayRshape :: ShapeR sh
            , arrayRtype  :: TypeR e
            }
         -> ArrayR (Array sh e)

instance Show (ArrayR a) where
  show (ArrayR shR tp) = "Array DIM" ++ show (rank shR) ++ " " ++ show tp

type ArraysR = TupR ArrayR

instance Show (TupR ArrayR e) where
  show TupRunit           = "()"
  show (TupRsingle aR)    = show aR
  show (TupRpair aR1 aR2) = "(" ++ show aR1 ++ "," ++ show aR2 ++ ")"

showArraysR :: ArraysR a -> ShowS
showArraysR = shows

arraysRarray :: ShapeR sh -> TypeR e -> ArraysR (Array sh e)
arraysRarray shR tp = TupRsingle (ArrayR shR tp)

arraysRpair :: ArrayR a -> ArrayR b -> ArraysR (((), a), b)
arraysRpair a b = TupRunit `TupRpair` TupRsingle a `TupRpair` TupRsingle b

arraysRFunctionImpossible :: ArraysR (s -> t) -> a
arraysRFunctionImpossible (TupRsingle repr) = case repr of {}

-- | Creates a new, uninitialized Accelerate array.
--
allocateArray :: ArrayR (Array sh e) -> sh -> IO (Array sh e)
allocateArray (ArrayR shR tp) sh = do
  mbuffers <- newBuffers tp (size shR sh)
  let buffers = unsafeFreezeBuffers tp mbuffers
  return $! Array sh buffers

-- | Create an array from its representation function, applied at each
-- index of the array.
--
fromFunction :: ArrayR (Array sh e) -> sh -> (sh -> e) -> Array sh e
fromFunction repr sh f = unsafePerformIO $! fromFunctionM repr sh (return . f)

-- | Create an array using a monadic function applied at each index.
--
-- @since 1.2.0.0
--
fromFunctionM :: ArrayR (Array sh e) -> sh -> (sh -> IO e) -> IO (Array sh e)
fromFunctionM (ArrayR shR tp) sh f = do
  let !n = size shR sh
  mbuffers <- newBuffers tp n
  --
  let write !i
        | i >= n    = return ()
        | otherwise = do
            v <- f (fromIndex shR sh i)
            writeBuffers tp mbuffers i v
            write (i+1)
  --
  write 0
  let buffers = unsafeFreezeBuffers tp mbuffers
  return $! buffers `seq` Array sh buffers


-- | Convert a list into an Accelerate 'Array' in dense row-major order.
--
fromList :: forall sh e. ArrayR (Array sh e) -> sh -> [e] -> Array sh e
fromList (ArrayR shR tp) sh xs = buffers `seq` Array sh buffers
  where
    -- Assume the array is in dense row-major order. This is safe because
    -- otherwise backends would not be able to directly memcpy.
    --
    !n    = size shR sh
    (buffers, _) = runBuffers tp $ do
                  mbuffers <- newBuffers tp n
                  let go !i _ | i >= n = return ()
                      go !i (v:vs)     = writeBuffers tp mbuffers i v >> go (i+1) vs
                      go _  []         = error "Data.Array.Accelerate.fromList: not enough input data"
                  --
                  go 0 xs
                  return (mbuffers, undefined)


-- | Convert an accelerated 'Array' to a list in row-major order.
--
toList :: ArrayR (Array sh e) -> Array sh e -> [e]
toList (ArrayR shR tp) (Array sh buffers) = go 0
  where
    -- Assume underling array is in row-major order. This is safe because
    -- otherwise backends would not be able to directly memcpy.
    --
    !n                  = size shR sh
    go !i | i >= n      = []
          | otherwise   = indexBuffers tp buffers i : go (i+1)

concatVectors :: forall e. TypeR e -> [Vector e] -> Vector e
concatVectors tp vs = buffers `seq` Array ((), len) buffers
  where
    offsets      = scanl (+) 0 (map (size dim1 . shape) vs)
    len          = last offsets
    (buffers, _) = runBuffers tp $ do
      mbuffers <- newBuffers tp len
      sequence_ [ writeBuffers tp mbuffers (i + k) (indexBuffers tp ad i)
                | (Array ((), n) ad, k) <- vs `zip` offsets
                , i <- [0 .. n - 1] ]
      return (mbuffers, undefined)

shape :: Array sh e -> sh
shape (Array sh _) = sh

reshape :: HasCallStack => ShapeR sh -> sh -> ShapeR sh' -> Array sh' e -> Array sh e
reshape shR sh shR' (Array sh' adata)
  = boundsCheck "shape mismatch" (size shR sh == size shR' sh')
  $ Array sh adata

(!) :: (ArrayR (Array sh e), Array sh e) -> sh -> e
(!) = uncurry indexArray

(!!) :: (TypeR e, Array sh e) -> Int -> e
(!!) = uncurry linearIndexArray

indexArray :: ArrayR (Array sh e) -> Array sh e -> sh -> e
indexArray (ArrayR shR tp) (Array sh buffers) ix = indexBuffers tp buffers (toIndex shR sh ix)

linearIndexArray :: TypeR e -> Array sh e -> Int -> e
linearIndexArray tp (Array _ buffers) = indexBuffers tp buffers

showArray :: (e -> ShowS) -> ArrayR (Array sh e) -> Array sh e -> String
showArray f arrR@(ArrayR shR _) arr@(Array sh _) = case shR of
  ShapeRz                         -> "Scalar Z "                       ++ list
  ShapeRsnoc ShapeRz              -> "Vector (" ++ shapeString ++ ") " ++ list
  ShapeRsnoc (ShapeRsnoc ShapeRz) -> "Matrix (" ++ shapeString ++ ") " ++ showMatrix f arrR arr
  _                               -> "Array ("  ++ shapeString ++ ") " ++ list
  where
    shapeString = showShape shR sh
    list        = showListWith f (toList arrR arr) ""

showArrayShort :: Int -> (e -> ShowS) -> ArrayR (Array sh e) -> Array sh e -> String
showArrayShort n f arrR arr = '[' : go 0 (toList arrR arr)
  where
    go _ []       = "]"
    go i (x:xs)
      | i >= n    = " ..]"
      | otherwise = ',' : f x (go (i+1) xs)

-- TODO: Make special formatting optional? It is more difficult to
-- copy/paste the result, for example. Also it does not look good if the
-- matrix row does not fit on a single line.
--
showMatrix :: (e -> ShowS) -> ArrayR (Array DIM2 e) -> Array DIM2 e -> String
showMatrix f (ArrayR _ arrR) arr@(Array sh _)
  | rows * cols == 0 = "[]"
  | otherwise        = "\n  [" ++ ppMat 0 0
    where
      (((), rows), cols) = sh
      lengths            = U.generate (rows*cols) (\i -> length (f (linearIndexArray arrR arr i) ""))
      widths             = U.generate cols (\c -> U.maximum (U.generate rows (\r -> lengths U.! (r*cols+c))))
      --
      ppMat :: Int -> Int -> String
      ppMat !r !c | c >= cols = ppMat (r+1) 0
      ppMat !r !c             =
        let
            !i    = r*cols+c
            !l    = lengths U.! i
            !w    = widths  U.! c
            !pad  = 1
            cell  = replicate (w-l+pad) ' ' ++ f (linearIndexArray arrR arr i) ""
            --
            before
              | r > 0 && c == 0 = "\n   "
              | otherwise       = ""
            --
            after
              | r >= rows-1 && c >= cols-1 = "]"
              | otherwise                  = ',' : ppMat r (c+1)
        in
        before ++ cell ++ after

reduceRank :: ArrayR (Array (sh, Int) e) -> ArrayR (Array sh e)
reduceRank (ArrayR (ShapeRsnoc shR) aeR) = ArrayR shR aeR

rnfArray :: ArrayR a -> a -> ()
rnfArray (ArrayR shR tp) (Array sh buffers) = rnfShape shR sh `seq` rnfBuffers tp buffers

rnfArrayR :: ArrayR arr -> ()
rnfArrayR (ArrayR shR tp) = rnfShapeR shR `seq` rnfTupR rnfScalarType tp

rnfArraysR :: ArraysR arrs -> arrs -> ()
rnfArraysR TupRunit           ()      = ()
rnfArraysR (TupRsingle arrR)  arr     = rnfArray arrR arr
rnfArraysR (TupRpair aR1 aR2) (a1,a2) = rnfArraysR aR1 a1 `seq` rnfArraysR aR2 a2

liftArrayR :: ArrayR a -> Q (TExp (ArrayR a))
liftArrayR (ArrayR shR tp) = [|| ArrayR $$(liftShapeR shR) $$(liftTypeR tp) ||]

liftArraysR :: ArraysR arrs -> Q (TExp (ArraysR arrs))
liftArraysR TupRunit          = [|| TupRunit ||]
liftArraysR (TupRsingle repr) = [|| TupRsingle $$(liftArrayR repr) ||]
liftArraysR (TupRpair a b)    = [|| TupRpair $$(liftArraysR a) $$(liftArraysR b) ||]

liftArray :: forall sh e. ArrayR (Array sh e) -> Array sh e -> Q (TExp (Array sh e))
liftArray (ArrayR shR tp) (Array sh buffers) =
  [|| Array $$(liftElt (shapeType shR) sh) $$(liftBuffers sz tp buffers) ||] `at` [t| Array $(liftTypeQ (shapeType shR)) $(liftTypeQ tp) |]
  where
    sz :: Int
    sz = size shR sh

    at :: Q (TExp t) -> Q Type -> Q (TExp t)
    at e t = unsafeTExpCoerce $ sigE (unTypeQ e) t

