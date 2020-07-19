{-# LANGUAGE OverloadedStrings, OverloadedLabels, FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE GADTs #-}

module Main (main) where

import Control.Concurrent
import Control.Monad
import Control.Monad (when)
import Control.Monad.Trans.Reader (runReaderT)
import Data.IORef
import qualified Data.IntMap as IntMap
import Data.Maybe (fromJust)

import Data.GI.Base
import qualified GI.Cairo as GI.Cairo
import qualified GI.GLib as GLib
import qualified GI.Gdk as Gdk
import qualified GI.GdkPixbuf as GP
import qualified GI.Gio as Gio
import qualified GI.Gtk as Gtk

import Foreign.Ptr (castPtr)
import Graphics.Rendering.Cairo
import Graphics.Rendering.Cairo.Internal (Render(runRender))
import Graphics.Rendering.Cairo.Types (Cairo(Cairo))

-- | A graphical element that can be clicked
data Element = Element
  { _elPosition :: !(Int, Int) -- ^ (x, y) of top left corner
  , _elSize :: !(Int, Int)  -- ^ (width, height)
  , _elZ :: Int -- ^ Depth. Higher values are drawn on top
  }

data AppState = AppState
  { _asMovingNode :: Maybe Int -- ^ _asElements key
  , _asEdges :: [(Element, Element)]
  , _asMouseXandY :: !(Double, Double)
  , _asElements :: IntMap.IntMap Element
  }

emptyAppState = AppState
  { _asMovingNode = Nothing
  , _asEdges = []
  , _asMouseXandY = (0, 0)
  , _asElements = mempty
  }

renderCairo c r = withManagedPtr c $ \pointer ->
  runReaderT (runRender r) (Cairo (castPtr pointer))

-- TODO Add type signature
getXandY event =
  (\x y -> (x, y)) <$> get event #x <*> get event #y

-- updateCanvas :: WidgetClass widget => widget -> PangoLayout -> Render ()
drawLine (fromX, fromY) (toX, toY) = do
  setSourceRGB 0 1 0
  setLineWidth 5

  moveTo fromX fromY
  lineTo toX toY
  stroke

drawCircle (x, y) = do
--   setSourceRGB 1 0 0
  setLineWidth 1
  -- moveTo x y
  let radius = 20
  let tau = 2 * pi
  arc x y radius 0 tau
  stroke

updateBackground canvas state = do
  width  <- realToFrac <$> (liftIO $ Gtk.widgetGetAllocatedWidth  canvas)
  height <- realToFrac <$> (liftIO $ Gtk.widgetGetAllocatedHeight canvas)

  -- TODO This should be moved into the setup phase
  setSourceRGB 0 0 0
  paint

  stateVal <- liftIO $ readIORef state
  setSourceRGB 1 0 0
  drawCircle (_asMouseXandY stateVal)

startApp :: Gtk.Application -> IO ()
startApp app = do
  state <- newIORef emptyAppState
  window <- new Gtk.ApplicationWindow
    [ #application := app
    , #title := "Glance"
    , #defaultWidth := 500
    , #defaultHeight := 500
    , #borderWidth := 0
    ]
  backgroundArea <- new Gtk.DrawingArea []
  Gtk.widgetAddEvents backgroundArea
    [ Gdk.EventMaskPointerMotionMask
    , Gdk.EventMaskButtonPressMask]
  #add window backgroundArea

  geometry <- new Gdk.Geometry [ #minWidth := 500, #minHeight := 500]

  -- screen <- get window #screen
  -- rgbaVisual <- #getRgbaVisual screen
  -- #setVisual window rgbaVisual

  -- No noticable change with setting this to GLib.PRIORITY_DEFAULT
  -- GLib.timeoutAdd GLib.PRIORITY_LOW 1 (#queueDraw backgroundArea >> pure True)

  surfaceRef <- newIORef (Nothing)

  _ <- on backgroundArea #draw (\context -> do
    mSurface <- readIORef surfaceRef
    surface <- case mSurface of
      Nothing -> do
        (width, height) <- #getSize window
        surf <- createImageSurface
          FormatARGB32
          (fromIntegral width)
          (fromIntegral height)
        writeIORef surfaceRef $ Just $ surf
        pure surf
      Just surface -> pure surface

    renderCairo context (updateBackground backgroundArea state)
    pure True)

  let
    timeoutCallback :: IO Bool
    timeoutCallback = do
      gdkWindow <- fromJust <$> #getWindow window
      display <- fmap fromJust Gdk.displayGetDefault -- TODO unsafe
      deviceManager <- fromJust <$> Gdk.displayGetDeviceManager display -- TODO deprecated
      device <- Gdk.deviceManagerGetClientPointer deviceManager
      gdkDevicePosition <- Gdk.windowGetDevicePositionDouble gdkWindow device
      let (_, x, y, _) = gdkDevicePosition
      print (x, y)
      #queueDraw backgroundArea
      pure True

  GLib.timeoutAdd GLib.PRIORITY_LOW 1 (timeoutCallback)

  let
    motionCallback eventMotion = do
      -- print "motion callback"
      mousePosition <- getXandY eventMotion
      -- print mousePosition
      modifyIORef' state
        (\s@AppState{_asMouseXandY}
         -> s{_asMouseXandY=mousePosition}
        )
      pure False
  _ <- on backgroundArea #motionNotifyEvent motionCallback

  let
    backgroundPress _ = do
      putStrLn "backgroundPressed"
      pure True
  on backgroundArea #buttonPressEvent backgroundPress

  #showAll window
  pure ()

main :: IO ()
main = do
  app <- new Gtk.Application []
  _ <- on app #activate (startApp app)
  status <- Gio.applicationRun app Nothing
  putStrLn ("Application status is " <> show status)
  pure ()
