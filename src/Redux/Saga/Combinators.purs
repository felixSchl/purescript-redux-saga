module Redux.Saga.Combinators where

-- module Redux.Saga.Combinators (
--     debounce
--   ) where

-- import Control.Monad.Aff (delay)
-- import Control.Monad.Aff.Class (liftAff)
-- import Data.Foldable (for_)
-- import Data.Maybe (Maybe(..))
-- import Data.Time.Duration (class Duration, fromDuration)
-- import Prelude (discard, ($), (<<<), (=<<))
-- import Redux.Saga (Saga', cancelTask, forkNamed, take)

-- debounce
--   :: ∀ env state input output a duration
--    . Duration duration
--   => duration
--   -> (input -> Maybe (Saga' env state input output a))
--   -> Saga' env state input output a
-- debounce duration f = go Nothing
--   where
--   go mTask = do
--     go <<< Just =<< take \a -> case f a of
--       Just saga -> Just do
--         forkNamed "debounced" do
--           for_ mTask cancelTask
--           liftAff $ delay $ fromDuration duration
--           saga
--       Nothing -> Nothing
