module Test.Main where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Array as Array
import Data.Time.Duration (Milliseconds(..))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Aff (Aff, launchAff, delay)
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (newRef, modifyRef, REF, readRef)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff)
import Control.Monad.Eff.Uncurried (mkEffFn1)
import Control.Monad.Eff.Console as Console
import Control.Monad.Eff.Console (CONSOLE)
import Control.Monad.Eff.Exception (EXCEPTION)
import Control.Monad.Eff.Class (liftEff)
import React.Redux as Redux
import React.Redux (REDUX, ReduxReactClass')

import Saga (Saga, takeEvery, take, fork, put, joinTask, sagaMiddleware)

data Action = SearchChanged String
type GlobalState = {}

mySaga :: ∀ eff. Saga (console :: CONSOLE | eff) Action GlobalState Unit
mySaga = do
  task <- takeEvery $ case _ of
    SearchChanged q -> Just do
      liftEff $ Console.log $ "Handling search: " <> show q
      liftAff $ delay $ 1000.0 # Milliseconds
    _ -> Nothing
  liftEff $ Console.log $ "Waiting..."
  put $ SearchChanged "search this"
  put $ SearchChanged "... and this"

mkStore
  :: ∀ eff
   . Saga eff Action GlobalState Unit
  -> Eff  (Redux.ReduxEffect _)
          (Redux.Store Action GlobalState)
mkStore saga = Redux.createStore reducer initialState middlewareEnhancer

  where
  initialState :: GlobalState
  initialState = {}

  reducer :: Redux.Reducer Action GlobalState
  reducer action state = state

  middlewareEnhancer :: Redux.Enhancer _ Action GlobalState
  middlewareEnhancer = Redux.applyMiddleware  [ sagaMiddleware saga ]

main :: ∀ eff. Eff _ Unit
main = void $ mkStore mySaga
