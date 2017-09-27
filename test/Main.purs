module Test.Main where

import Prelude
import Redux.Saga

import Control.Monad.Aff (delay)
import Control.Monad.Aff.AVar (makeVar, takeVar, putVar)
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Ref (newRef, modifyRef, readRef)
import Control.Safely (replicateM_)
import Data.Array as A
import Data.List.Lazy (replicateM)
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import React.Redux (ReduxEffect)
import React.Redux as Redux
import Test.Spec (pending, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter.Console (consoleReporter)
import Test.Spec.Runner (RunnerEffects, run)

data Action = SearchChanged String
type GlobalState = {}

mkStore
  :: ∀ action state eff
   . Redux.Reducer action state
  -> state
  -> Saga eff action state Unit
  -> Eff _ (Redux.Store action state)
mkStore reducer initialState saga
    = Redux.createStore reducer
                        initialState
                        $ Redux.applyMiddleware  [ sagaMiddleware saga ]

withCompletionVar f = do
  completedVar <- liftAff makeVar
  f $ putVar completedVar
  liftAff $ takeVar completedVar

main :: Eff _ Unit
main = run [consoleReporter] do
  describe "sagas" do
    describe "take" do
      it "should run handler" do
        r <- withCompletionVar \done -> do
          liftEff $ void $ mkStore (const id) {} do
            void $ fork do
              take \i -> pure do
                liftAff $ done i
            put 1
        r `shouldEqual` 1

      it "should run handler" do
        r <- withCompletionVar \done -> do
          liftEff $ void $ mkStore (const id) {} do
            void $ fork do
              take case _ of
                n | n == 2 -> pure $ liftAff $ done n
                _ -> Nothing
            put 1
            put 2
        r `shouldEqual` 2

      it "should run handler" do
        r <- withCompletionVar \done -> do
          liftEff $ void $ mkStore (const id) {} do
            ref <- liftEff $ newRef []
            void $ fork do
              replicateM_ 3 do
                take \i -> pure do
                  liftEff $ modifyRef ref (_ `A.snoc` i)
              liftEff (readRef ref) >>= liftAff <<< done
            put 1
            put 2
            put 3
        r `shouldEqual` [1, 2, 3]
