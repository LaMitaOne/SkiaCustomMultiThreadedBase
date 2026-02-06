{*******************************************************************************
  SkiaCustomMultiThreadedBase
********************************************************************************
  A high-performance, multi-threaded FMX Skia component.
  Utilizing Skia4Delphi for off-screen rendering.
  Key Features:
  - Multi-Threaded Architecture: Separates Logic/Rendering from the UI Thread.
  - Non-Blocking UI: Main thread remains responsive even at high load.
  - Double Buffering: Renders to offscreen surfaces to prevent flickering.
  - Strip Rendering: Divides the screen into adjustable horizontal strips.
  How it Works:
  1. Background Thread: Runs logic and draws all strips sequentially to a
     shared off-screen surface.
  2. Main Thread: Takes the completed snapshot and draws it to the screen.
  3. This prevents UI freezing and ensures smooth animation.
*******************************************************************************}
{ SkiaCustomMultiThreadedBase v0.1                                                   }
{ by The Developer                                                                }
{                                                                              }
{------------------------------------------------------------------------------}
{
  Latest Changes:
   v 0.1:
   - Implemented Doublebuffering logic.
   - Implemented Background Thread Logic.
   - Implemented Sequential Strip Rendering.
   - Added Dirty Rect optimization in sample (Only redraws if logic changed).
}


unit uSkiaCustomMultiThreadedBase;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.SyncObjs, System.Threading, FMX.Types, FMX.Controls, FMX.Skia,
  System.Skia;

type
  { TSkiaCustomThreadedBase
    A high-performance, thread-rendered FMX Skia component.
    Utilizing Skia4Delphi for off-screen rendering.
    Key Features:
    - Multi-Threaded Architecture: Separates Logic/Rendering from the UI Thread.
    - Non-Blocking UI: Main thread remains responsive even at high load.
    - Double Buffering: Renders to offscreen surfaces to prevent flickering.
    - Strip Rendering: Divides the screen into adjustable horizontal strips.
    How it Works:
    1. Background Thread: Runs logic and draws all strips sequentially to a
       shared off-screen surface.
    2. Main Thread: Takes the completed snapshot and draws it to the screen.
    3. This prevents UI freezing and ensures smooth animation.
  }
  TSkiaCustomMultiThreadedBase = class(TSkCustomControl)
  private
    { ========================================================================
      Threading & Synchronization
      ======================================================================== }
    FRenderThread: TThread;      // The dedicated background render thread
    FLock: TCriticalSection;     // Lock to safely swap the BackBuffer
    FEvent: TEvent;             // Event object for thread signaling
    FTargetFPS: Integer;         // Desired frames per second cap
    FTerminate: Boolean;         // Flag to signal the thread to stop
    { ========================================================================
      Rendering & Buffering
      ======================================================================== }
    FBackBuffer: ISkImage;       // The completed image to show on screen
    FFrameCount: Integer;        // Counter for calculating real FPS
    FLastFpsCheck: Cardinal;     // Timestamp of last FPS update
    FRealFPS: Integer;           // The calculated FPS value
    { ========================================================================
      Logic & Optimization
      ======================================================================== }
    FNeedsRedraw: Boolean;       // Optimization: Only render if something changed
    FActive: Boolean;            // Master switch for the animation
    FWorkerCount: Integer;       // Number of horizontal strips to render
    { ========================================================================
      Demo State (Simulation Data)
      ======================================================================== }
    FDemoRect: TRectF;          // Position of the bouncing box
    FDemoVelocity: TPointF;     // Speed and direction of the box
    FAngle: Single;             // Angle for pulsating effect
    FPrevRect: TRectF;         // Previous position (for dirty checking)
    FPrevActive: Boolean;       // Previous active state
    { ========================================================================
      Property Setters
      ======================================================================== }
    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);
    procedure SetWorkerCount(const Value: Integer);
    { ========================================================================
      Internal Thread Methods
      ======================================================================== }
    procedure ThreadSafeInvalidate;
    procedure StartRenderThread;
    procedure StopRenderLoop;
    procedure RenderFrame;
  protected
    procedure Resize; override;
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    { ========================================================================
      Virtual Methods (Override these to draw your own content)
      ======================================================================== }
    // 1. Update Math/Physics here
    procedure UpdateLogic(const DeltaTime: Double); virtual;
    // 2. Draw content here
    procedure RenderStrip(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double; const AStripIndex: Integer; const AObjectRect: TRectF; const AAngle: Single; const AIsActive: Boolean); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property RealFPS: Integer read FRealFPS; // Read-only FPS counter
    property WorkerCount: Integer read FWorkerCount write SetWorkerCount default 4;
  published
    property Align;
    property HitTest default True;
    property Opacity;
    property Visible;
    property Width;
    property Height;
    property Active: Boolean read FActive write SetActive default False;
    property TargetFPS: Integer read FTargetFPS write SetTargetFPS default 60;
  end;

implementation
{==============================================================================
  TSkiaCustomThreadedBase - Implementation
==============================================================================}

constructor TSkiaCustomMultiThreadedBase.Create(AOwner: TComponent);
begin
  inherited;
  // Initialize synchronization objects
  FLock := TCriticalSection.Create;
  FEvent := TEvent.Create(nil, False, False, '');
  FTargetFPS := 60;
  FWorkerCount := 4; // Default to 4 horizontal strips
  FRealFPS := 0;
  FLastFpsCheck := TThread.GetTickCount;
  FTerminate := False;
  SetBounds(0, 0, 300, 200);
  HitTest := True;
  // Initialize Demo State
  FDemoRect := TRectF.Create(50, 50, 100, 100);
  FDemoVelocity := TPointF.Create(150, 100);
  FAngle := 0.0;
  FPrevRect := FDemoRect;
  FPrevActive := False;
  FNeedsRedraw := True;
end;

destructor TSkiaCustomMultiThreadedBase.Destroy;
begin
  // Ensure thread stops before destroying
  StopRenderLoop;
  FreeAndNil(FEvent);
  FreeAndNil(FLock);
  inherited;
end;

procedure TSkiaCustomMultiThreadedBase.Resize;
begin
  inherited;
  // Mark as needing redraw when resized
  FNeedsRedraw := True;
end;

procedure TSkiaCustomMultiThreadedBase.SetWorkerCount(const Value: Integer);
begin
  if FWorkerCount <> Value then
    FWorkerCount := Value;
end;
{------------------------------------------------------------------------------
  Thread Management
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.StartRenderThread;
begin
  // Prevent multiple thread instances
  if Assigned(FRenderThread) then
    Exit;
  FTerminate := False;
  // Create the background thread loop
  FRenderThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, CurrentTime: Cardinal;
      SleepTime: Integer;
    begin
      LastTime := TThread.GetTickCount;
      while not FTerminate do
      begin
        // Execute the heavy rendering work
        if FActive or FNeedsRedraw then
          RenderFrame;
        // FPS Control (Sleep to maintain TargetFPS)
        CurrentTime := TThread.GetTickCount;
        if FTargetFPS > 0 then
          SleepTime := Round(1000 / FTargetFPS) - (CurrentTime - LastTime)
        else
          SleepTime := 0;
        if SleepTime < 0 then
          SleepTime := 0;
        if SleepTime > 0 then
          Sleep(SleepTime);
        LastTime := TThread.GetTickCount;
      end;
    end);
  FRenderThread.FreeOnTerminate := False;
  FRenderThread.Start;
end;

procedure TSkiaCustomMultiThreadedBase.StopRenderLoop;
begin
  FTerminate := True;
  if Assigned(FRenderThread) then
  begin
    FRenderThread.WaitFor;
    FreeAndNil(FRenderThread);
  end;
end;

procedure TSkiaCustomMultiThreadedBase.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if not Assigned(FRenderThread) then
        StartRenderThread;
    end;
    FNeedsRedraw := True;
    ThreadSafeInvalidate;
  end;
end;

procedure TSkiaCustomMultiThreadedBase.SetTargetFPS(const Value: Integer);
begin
  if FTargetFPS <> Value then
    FTargetFPS := Value;
end;
// Safely request a UI update from the background thread

procedure TSkiaCustomMultiThreadedBase.ThreadSafeInvalidate;
begin
  if csDestroying in ComponentState then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
        Self.Redraw;
    end);
end;
{------------------------------------------------------------------------------
  Core Rendering Logic (Runs in Background Thread)
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.RenderFrame;
var
  SharedSurface: ISkSurface;
  TotalHeight, StripHeight: Integer;
  i: Integer;
  CurrentRect: TRectF;
  CurrentActive: Boolean;
  CurrentAngle: Single;
  ClearPaint: ISkPaint;
  BorderPaint: ISkPaint;
  LocalRect: TRectF;
begin
  if FTerminate then
    Exit;
  // 1. Update Logic (Physics, Math)
  if FActive then
    UpdateLogic(0.016);
  // 2. Optimization: Skip rendering if nothing changed
  if not FNeedsRedraw then
    Exit;
  FNeedsRedraw := False;
  if (Width <= 1) or (Height <= 1) then
    Exit;
  // Capture State for this frame
  CurrentRect := FDemoRect;
  CurrentActive := FActive;
  CurrentAngle := FAngle;
  // 3. Create the Main Offscreen Surface (The Canvas)
  SharedSurface := TSkSurface.MakeRaster(Round(Width), Round(Height));
  if not Assigned(SharedSurface) then
    Exit;
  // 4. Calculate Strip Dimensions
  TotalHeight := Round(Height);
  StripHeight := TotalHeight div FWorkerCount;
  if (TotalHeight mod FWorkerCount) <> 0 then
    StripHeight := StripHeight + 1; // Ensure remainder is covered
  // 5. Prepare Paints (Optimization: Create once per frame)
  ClearPaint := TSkPaint.Create(TSkPaintStyle.Fill);
  ClearPaint.Color := TAlphaColors.Black;
  BorderPaint := TSkPaint.Create;
  BorderPaint.Style := TSkPaintStyle.Stroke;
  BorderPaint.Color := $FF00FF00; // Green Border
  BorderPaint.StrokeWidth := 2;
  // 6. Render Loop: Draw all strips sequentially
  for i := 0 to FWorkerCount - 1 do
  begin
    var StripIndex := i;
    var H := StripHeight;
    var StripY: Integer;
    var CurrentH: Integer;
    StripY := StripIndex * H;
    if StripY >= TotalHeight then
      Break;
    // Handle the last strip to cover any remaining pixels
    if StripIndex = FWorkerCount - 1 then
      CurrentH := TotalHeight - StripY
    else
      CurrentH := H;
    if CurrentH <= 0 then
      Continue;
    SharedSurface.Canvas.Save;
    try
      // A. Translate Canvas to the strip's position
      // This acts like moving the "paper" to the correct row
      SharedSurface.Canvas.Translate(0, StripY);
      // B. Clear the strip area
      SharedSurface.Canvas.DrawRect(TRectF.Create(0, 0, Width, CurrentH), ClearPaint);
      // C. Draw Debug Border (Visualizing the strips)
      SharedSurface.Canvas.DrawRect(TRectF.Create(0, 0, Width, CurrentH), BorderPaint);
      // D. Render User Content
      // We pass the 'Real Y' (StripY) in ATime to help calculate local coordinates
      LocalRect := CurrentRect;
      RenderStrip(SharedSurface.Canvas, TRectF.Create(0, 0, Width, CurrentH), StripY, StripIndex, LocalRect, CurrentAngle, CurrentActive);
    finally
      // Restore canvas state for next loop iteration
      SharedSurface.Canvas.Restore;
    end;
  end;
  // 7. Finalize: Snapshot the surface and send to UI
  if not FTerminate then
  begin
    FBackBuffer := SharedSurface.MakeImageSnapshot;
    ThreadSafeInvalidate;
  end;
end;
{------------------------------------------------------------------------------
  Main Thread Drawing (Runs in UI Thread)
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  ImageToDraw: ISkImage;
  CurrentTime: Cardinal;
begin
  // 1. Retrieve the finished image from the background thread
  FLock.Acquire;
  try
    ImageToDraw := FBackBuffer;
  finally
    FLock.Release;
  end;
  if Assigned(ImageToDraw) then
  begin
    // 2. Draw the completed image to the screen
    ACanvas.DrawImage(ImageToDraw, 0, 0, TSkSamplingOptions.High);
    // 3. Calculate FPS
    Inc(FFrameCount);
    CurrentTime := TThread.GetTickCount;
    if (CurrentTime - FLastFpsCheck) >= 1000 then
    begin
      FRealFPS := FFrameCount;
      FFrameCount := 0;
      FLastFpsCheck := CurrentTime;
    end;
  end
  else
    ACanvas.Clear(TAlphaColors.Gray);
end;
{------------------------------------------------------------------------------
  Demo Logic & Rendering (Overridable by user)
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.UpdateLogic(const DeltaTime: Double);
begin
  // Move the demo rectangle
  FDemoRect.Offset(FDemoVelocity.X * DeltaTime, FDemoVelocity.Y * DeltaTime);
  // Bounce X
  if FDemoRect.Left < 0 then
  begin
    FDemoVelocity.X := Abs(FDemoVelocity.X);
    FDemoRect.Left := 0;
  end
  else if FDemoRect.Right > Width then
  begin
    FDemoVelocity.X := -Abs(FDemoVelocity.X);
    FDemoRect.Left := Width - FDemoRect.Width;
  end;
  // Bounce Y
  if FDemoRect.Top < 0 then
  begin
    FDemoVelocity.Y := Abs(FDemoVelocity.Y);
    FDemoRect.Top := 0;
  end
  else if FDemoRect.Bottom > Height then
  begin
    FDemoVelocity.Y := -Abs(FDemoVelocity.Y);
    FDemoRect.Top := Height - FDemoRect.Height;
  end;
  // Animate Angle
  FAngle := FAngle + (3.0 * DeltaTime);
  // Mark as dirty if position changed
  if (FDemoRect.Left <> FPrevRect.Left) or (FActive <> FPrevActive) then
  begin
    FNeedsRedraw := True;
    FPrevRect := FDemoRect;
    FPrevActive := FActive;
  end;
end;

procedure TSkiaCustomMultiThreadedBase.RenderStrip(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double; const AStripIndex: Integer; const AObjectRect: TRectF; const AAngle: Single; const AIsActive: Boolean);
var
  Paint: ISkPaint;
  DrawRect: TRectF;
  StripY: Single;
begin
  { 1. ALWAYS DRAW THE STRIP BACKGROUND  }
  // Even if not active, we must clear the strip so old frames don't show through
  Paint := TSkPaint.Create;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.Color := TAlphaColors.Black;
  ACanvas.DrawRect(ADest, Paint); // Clear the specific strip area

  { 2. ONLY DRAW THE ANIMATED OBJECT IF ACTIVE }
  if AIsActive then
  begin
    StripY := ATime;
    // Calculate Local Position
    DrawRect := TRectF.Create(AObjectRect.Left, AObjectRect.Top - StripY, AObjectRect.Right, AObjectRect.Bottom - StripY);

    // Draw the Box
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := $FFFF0000; // RED
    Paint.AlphaF := 1.0;
    ACanvas.DrawRect(DrawRect, Paint);

    // Draw Border
    Paint.Style := TSkPaintStyle.Stroke;
    Paint.StrokeWidth := 2;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawRect(DrawRect, Paint);
  end;
end;

end.

