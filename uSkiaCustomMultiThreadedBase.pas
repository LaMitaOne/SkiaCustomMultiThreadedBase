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
  - Thread Staggering: Uses high-precision timing to start workers without CPU spikes.
  - Persistent Buffers: Allocates resources once to minimize memory overhead.

  How it Works:
  1. Background Threads: Logic runs on the main loop, but rendering is split
     across multiple worker threads, each drawing a specific strip.
  2. Thread Stagger: Workers are started with nanosecond delays (150ns) to
     distribute CPU load evenly.
  3. Main Thread: Takes the completed snapshots and composites them to the
     screen.
  4. This prevents UI freezing and ensures smooth animation at hardware limits.


*******************************************************************************}
{ SkiaCustomMultiThreadedBase v0.3                                           }
{ by Lara Miriam Tamy Reschke                                                  }
{                                                                              }
{------------------------------------------------------------------------------}
{
  Latest Changes:
   v 0.3:
   - Replaced Sleep/SwitchToThread with HighResTimer SpinWait.
   - Optimized stagger timing to 150ns for maximum throughput.
   - Implemented Persistent Buffering (created once) to reduce GC pressure.
   - Multi-threaded strip rendering with precise thread startup timing.
   v 0.2:
   - Initial multi-threaded strip architecture.
   v 0.1:
   - Implemented Doublebuffering logic.
   - Implemented Background Thread Logic.
   - Implemented Sequential Strip Rendering.
}
unit uSkiaCustomMultiThreadedBase;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.SyncObjs, System.Threading, FMX.Types, FMX.Controls, FMX.Skia,
  System.Skia, System.Diagnostics, System.TimeSpan
  {$IFDEF MSWINDOWS}
    , WinApi.Windows
  {$ENDIF};

type
  { High Precision Timer used to synchronize thread start times with
    nanosecond precision, avoiding the inaccuracy of standard OS sleep calls. }
  THighResTimer = record
    Frequency: Int64;
    procedure Init;
    function GetTicks: Int64; inline;
    procedure SpinWaitNanoseconds(const ANanoSeconds: Int64); inline;
  end;

  TSkiaCustomMultiThreadedBase = class(TSkCustomControl)
  private
    { Threading & Synchronization }
    FRenderThreads: TList;
    FLock: TCriticalSection;
    FEvent: TEvent;
    FTargetFPS: Integer;
    FTerminate: Boolean;
    FStopwatch: TStopwatch;
    FFrameTime: Double;
    FTimer: THighResTimer;

    { CPU Affinity Settings }
    FThreadAffinity: Integer;

    { Rendering Resources }
    FBackBuffer: ISkImage;             // Final image drawn to the UI
    FStripImages: array of ISkImage;    // Snapshots of individual strips
    FBackSurfaces: array of ISkSurface; // Persistent drawing surfaces for workers
    FFrameCount: Integer;
    FLastFpsTime: Double;
    FRealFPS: Integer;

    { Logic State }
    FNeedsRedraw: Boolean;
    FActive: Boolean;
    FWorkerCount: Integer;
    FStripsCompleted: Integer;
    FBufferValid: Boolean; // Tracks if buffer allocation matches current size

    { Demo State (Bouncing Box) }
    FDemoRect: TRectF;
    FDemoVelocity: TPointF;
    FAngle: Single;
    FPrevRect: TRectF;
    FPrevActive: Boolean;

    { Property Setters }
    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);
    procedure SetWorkerCount(const Value: Integer);
    procedure SetThreadAffinity(const Value: Integer);

    { Internal Methods }
    procedure ThreadSafeInvalidate;
    procedure StartRenderThreads;
    procedure StopRenderLoop;
    procedure RenderFrame;
    procedure AllocateBuffers;
  protected
    procedure Resize; override;
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure UpdateLogic(const DeltaTime: Double); virtual;
    procedure RenderStrip(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double; const AStripIndex: Integer; const AObjectRect: TRectF; const AAngle: Single; const AIsActive: Boolean); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property RealFPS: Integer read FRealFPS;
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
    property ThreadAffinity: Integer read FThreadAffinity write SetThreadAffinity default -1;
  end;

implementation

{==============================================================================
  THighResTimer Implementation
==============================================================================}

procedure THighResTimer.Init;
begin
  // Initialize the high performance counter frequency
  if not QueryPerformanceFrequency(Frequency) then
    Frequency := 0;
end;

function THighResTimer.GetTicks: Int64;
begin
  QueryPerformanceCounter(Result);
end;

procedure THighResTimer.SpinWaitNanoseconds(const ANanoSeconds: Int64);
var
  StartTicks, TargetTicks, CurrentTicks: Int64;
begin
  if (ANanoSeconds <= 0) or (Frequency = 0) then Exit;
  StartTicks := GetTicks;
  TargetTicks := StartTicks + (ANanoSeconds * Frequency) div 1000000000;
  repeat
    CurrentTicks := GetTicks;
    // Handle counter overflow (very rare)
    if (TargetTicks < StartTicks) and (CurrentTicks >= StartTicks) then
       Continue;
  until (CurrentTicks >= TargetTicks) or (CurrentTicks < StartTicks);
end;

{==============================================================================
  Internal Task Record
==============================================================================}

type
  PWorkerTask = ^TWorkerTask;
  { Record passed to each worker thread containing all data needed to render
    a specific strip, ensuring thread safety by using local copies. }
  TWorkerTask = record
    Owner: TSkiaCustomMultiThreadedBase;
    StripIndex: Integer;
    StripY: Integer;
    StripHeight: Integer;
    ObjRect: TRectF;
    Angle: Single;
    IsActive: Boolean;
  end;

{==============================================================================
  TSkiaCustomMultiThreadedBase
==============================================================================}

constructor TSkiaCustomMultiThreadedBase.Create(AOwner: TComponent);
begin
  inherited;
  FLock := TCriticalSection.Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FStopwatch := TStopwatch.Create;
  FRenderThreads := TList.Create;

  FTimer.Init;
  FTargetFPS := 60;
  FWorkerCount := 4;
  FRealFPS := 0;
  FLastFpsTime := 0;
  FStripsCompleted := 0;
  FThreadAffinity := -1;
  FBufferValid := False;

  SetBounds(0, 0, 300, 200);
  HitTest := True;

  // Initialize demo state
  FDemoRect := TRectF.Create(50, 50, 100, 100);
  FDemoVelocity := TPointF.Create(150, 100);
  FAngle := 0.0;
  FPrevRect := FDemoRect;
  FPrevActive := False;
  FNeedsRedraw := True;
end;

destructor TSkiaCustomMultiThreadedBase.Destroy;
begin
  StopRenderLoop;
  FreeAndNil(FEvent);
  FreeAndNil(FLock);
  FreeAndNil(FRenderThreads);
  inherited;
end;

procedure TSkiaCustomMultiThreadedBase.Resize;
begin
  inherited;
  // Invalidate buffers when size changes
  FNeedsRedraw := True;
  FBufferValid := False;
  SetLength(FStripImages, 0);
  SetLength(FBackSurfaces, 0);
end;

{------------------------------------------------------------------------------
  AllocateBuffers
  Creates the off-screen surfaces once. They are reused across frames to avoid
  memory allocation overhead.
------------------------------------------------------------------------------}
procedure TSkiaCustomMultiThreadedBase.AllocateBuffers;
var
  TotalHeight, StripHeight, i: Integer;
begin
  // Skip allocation if buffers are already valid for current size
  if FBufferValid then Exit;
  if (Width <= 1) or (Height <= 1) or (FWorkerCount <= 0) then Exit;

  FLock.Acquire;
  try
    if FBufferValid then Exit;

    TotalHeight := Round(Height);
    StripHeight := TotalHeight div FWorkerCount;
    // Adjust last strip height if division isn't perfect
    if (TotalHeight mod FWorkerCount) <> 0 then
      StripHeight := StripHeight + 1;

    SetLength(FBackSurfaces, FWorkerCount);
    SetLength(FStripImages, FWorkerCount);

    for i := 0 to FWorkerCount - 1 do
    begin
      var StripY := i * StripHeight;
      var CurrentH := StripHeight;
      // Ensure the last strip covers exactly to the bottom
      if i = FWorkerCount - 1 then
        CurrentH := TotalHeight - StripY;

      if CurrentH > 0 then
        // Create a raster surface for this strip
        FBackSurfaces[i] := TSkSurface.MakeRaster(Round(Width), CurrentH)
      else
        FBackSurfaces[i] := nil;
    end;
    FBufferValid := True;
  finally
    FLock.Release;
  end;
end;

{------------------------------------------------------------------------------
  Property Setters
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.SetWorkerCount(const Value: Integer);
begin
  if FWorkerCount <> Value then
  begin
    // Restart threads to apply new worker count
    if FActive then
    begin
      Active := False;
      FWorkerCount := Value;
      Active := True;
    end
    else
    begin
      FWorkerCount := Value;
      FBufferValid := False;
      SetLength(FBackSurfaces, 0);
    end;
  end;
end;

procedure TSkiaCustomMultiThreadedBase.SetThreadAffinity(const Value: Integer);
begin
  if FThreadAffinity <> Value then
  begin
    FThreadAffinity := Value;
    if FActive then
    begin
      Active := False;
      Active := True; // Restart threads to apply affinity
    end;
  end;
end;

procedure TSkiaCustomMultiThreadedBase.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if FRenderThreads.Count = 0 then
        StartRenderThreads;
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

{------------------------------------------------------------------------------
  ThreadSafeInvalidate
  Triggers a repaint on the UI thread safely from a background thread.
------------------------------------------------------------------------------}
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
  StartRenderThreads
  Initializes the main render loop thread.
------------------------------------------------------------------------------}
procedure TSkiaCustomMultiThreadedBase.StartRenderThreads;
begin
  if FRenderThreads.Count > 0 then
    Exit;

  FTerminate := False;
  FStopwatch.Reset;
  FStopwatch.Start;

  FRenderThreads.Add(TThread.CreateAnonymousThread(
    procedure
    var
      StartTime, EndTime, ElapsedMs: Double;
      SleepTime: Integer;
    begin
      StartTime := FStopwatch.Elapsed.TotalMilliseconds;
      while not FTerminate do
      begin
        RenderFrame;

        // FPS Control Logic
        EndTime := FStopwatch.Elapsed.TotalMilliseconds;
        ElapsedMs := EndTime - StartTime;

        if FTargetFPS > 0 then
          FFrameTime := 1000.0 / FTargetFPS
        else
          FFrameTime := 0.016;

        SleepTime := Round(FFrameTime - ElapsedMs);
        if SleepTime < 0 then
          SleepTime := 0; // Frame took too long, no sleep

        if SleepTime > 0 then
          Sleep(SleepTime);

        // Adjust start time to maintain long-term FPS stability
        StartTime := StartTime + FFrameTime;
        // Correct for massive drifts (e.g. debugger pause)
        if (FStopwatch.Elapsed.TotalMilliseconds - StartTime) > 1000 then
          StartTime := FStopwatch.Elapsed.TotalMilliseconds;
      end;
    end));
  TThread(FRenderThreads.Last).FreeOnTerminate := False;
  TThread(FRenderThreads.Last).Start;
end;

procedure TSkiaCustomMultiThreadedBase.StopRenderLoop;
begin
  FTerminate := True;
  if Assigned(FEvent) then
    FEvent.SetEvent;

  var I: Integer;
  for I := 0 to FRenderThreads.Count - 1 do
  begin
    TThread(FRenderThreads[I]).Terminate;
    TThread(FRenderThreads[I]).WaitFor;
    TThread(FRenderThreads[I]).Free;
  end;
  FRenderThreads.Clear;
end;

{------------------------------------------------------------------------------
  RenderFrame
  Main rendering orchestration. Prepares tasks, spawns workers, waits for
  completion, and composites the final result.
------------------------------------------------------------------------------}
procedure TSkiaCustomMultiThreadedBase.RenderFrame;
var
  MainSurface: ISkSurface;
  RunningThreads: array of TThread;
  TotalHeight, StripHeight, i: Integer;
  CurrentRect: TRectF;
  CurrentActive: Boolean;
  CurrentAngle: Single;
  DeltaTimeSec: Double;
  WorkerTask: TWorkerTask;
begin
  if FTerminate then
    Exit;

  // 1. Update Logic State
  if FTargetFPS > 0 then
    DeltaTimeSec := 1.0 / FTargetFPS
  else
    DeltaTimeSec := 0.016;

  if FActive then
    UpdateLogic(DeltaTimeSec);

  if not FNeedsRedraw then
    Exit;
  FNeedsRedraw := False;

  if (Width <= 1) or (Height <= 1) then
    Exit;

  // 2. Capture current state for this frame (Snapshot)
  CurrentRect := FDemoRect;
  CurrentActive := FActive;
  CurrentAngle := FAngle;

  // 3. Ensure Off-screen Buffers are allocated
  AllocateBuffers;
  if not FBufferValid then Exit;

  // 4. Calculate Strip Dimensions
  TotalHeight := Round(Height);
  StripHeight := TotalHeight div FWorkerCount;
  if (TotalHeight mod FWorkerCount) <> 0 then
    StripHeight := StripHeight + 1;

  SetLength(RunningThreads, FWorkerCount);
  // Create a target surface for compositing the strips
  MainSurface := TSkSurface.MakeRaster(Round(Width), TotalHeight);
  if not Assigned(MainSurface) then
    Exit;

  FStripsCompleted := 0;
  FEvent.ResetEvent;

  // ==========================================
  // PHASE 1: SPAWN WORKERS
  // ==========================================
  for i := 0 to FWorkerCount - 1 do
  begin
    var StripY := i * StripHeight;
    var CurrentH := StripHeight;
    var LIndex: Integer := i;

    // Calculate height for the last strip to fill remainder
    if LIndex = FWorkerCount - 1 then
      CurrentH := TotalHeight - StripY;

    if CurrentH <= 0 then
    begin
      // Strip has no height, mark as done immediately
      TMonitor.Enter(Self);
      try
        Inc(FStripsCompleted);
        if FStripsCompleted >= FWorkerCount then
          FEvent.SetEvent;
      finally
        TMonitor.Exit(Self);
      end;
      RunningThreads[LIndex] := nil;
      Continue;
    end;

    // Retrieve the persistent surface for this strip
    if not Assigned(FBackSurfaces[LIndex]) then
      Continue;

    // Clear the surface for reuse
    FBackSurfaces[LIndex].Canvas.Clear(TAlphaColors.Black);

    // Prepare the task record
    WorkerTask.Owner := Self;
    WorkerTask.StripIndex := LIndex;
    WorkerTask.StripY := StripY;
    WorkerTask.StripHeight := CurrentH;
    WorkerTask.ObjRect := CurrentRect;
    WorkerTask.Angle := CurrentAngle;
    WorkerTask.IsActive := CurrentActive;

    var LSurface: ISkSurface := FBackSurfaces[LIndex];

    // Create and start the worker thread
    RunningThreads[LIndex] := TThread.CreateAnonymousThread(
      procedure
      var
        Task: TWorkerTask;
        Surface: ISkSurface;
        LCanvas: ISkCanvas;
        SysInfo: TSystemInfo;
        AffinityMask: NativeUInt;
        LCpuId: Integer;
        Snapshot: ISkImage;
      begin
        // Copy parameters to local stack for thread safety
        Task := WorkerTask;
        Surface := LSurface;

        if not Assigned(Task.Owner) then
          Exit;

        try
          if not Assigned(Surface) then
            raise Exception.Create('Surface nil');

          // --- Affinity Setup ---
          {$IFDEF MSWINDOWS}
          if (Task.Owner.FThreadAffinity >= 0) then
            WinApi.Windows.SetThreadAffinityMask(GetCurrentThread, NativeUInt(1) shl Task.Owner.FThreadAffinity)
          else if (Task.Owner.FThreadAffinity) = -1 then
          begin
            WinApi.Windows.GetSystemInfo(SysInfo);
            LCpuId := Random(SysInfo.dwNumberOfProcessors);
            AffinityMask := NativeUInt(1) shl LCpuId;
            WinApi.Windows.SetThreadAffinityMask(GetCurrentThread, AffinityMask);
          end;
          {$ENDIF}

          // --- Render to Surface ---
          LCanvas := Surface.Canvas;
          LCanvas.Save;
          try
            Task.Owner.RenderStrip(LCanvas, TRectF.Create(0, 0, Task.Owner.Width, Task.StripHeight), Task.StripY, Task.StripIndex, Task.ObjRect, Task.Angle, Task.IsActive);
          finally
            LCanvas.Restore;
          end;

          // --- Create Snapshot ---
          // Capture the rendered strip as an immutable image
          Snapshot := Surface.MakeImageSnapshot;
          Task.Owner.FStripImages[Task.StripIndex] := Snapshot;

        finally
          // Signal completion
          if Assigned(Task.Owner) then
          begin
            TMonitor.Enter(Task.Owner);
            try
              Inc(Task.Owner.FStripsCompleted);
              if Task.Owner.FStripsCompleted >= Task.Owner.FWorkerCount then
                Task.Owner.FEvent.SetEvent;
            finally
              TMonitor.Exit(Task.Owner);
            end;
          end;
        end;
      end);

    RunningThreads[LIndex].FreeOnTerminate := False;
    RunningThreads[LIndex].Start;

    // ==========================================
    // STAGGER START TIMES
    // ==========================================
    // Spreading thread starts prevents CPU bursts and ensures smoother
    // operation on multi-core systems.
    if LIndex < FWorkerCount - 1 then
    begin
      // Wait 0.15 milliseconds before starting the next thread
      FTimer.SpinWaitNanoseconds(150000);
    end;
  end;

  // ==========================================
  // PHASE 2: WAIT FOR COMPLETION
  // ==========================================
  while FStripsCompleted < FWorkerCount do
  begin
    if FTerminate then
      Break;
    FEvent.WaitFor(INFINITE);
  end;

  // Cleanup thread objects
  for i := 0 to FWorkerCount - 1 do
  begin
    if Assigned(RunningThreads[i]) then
    begin
      RunningThreads[i].WaitFor;
      RunningThreads[i].Free;
      RunningThreads[i] := nil;
    end;
  end;

  // ==========================================
  // PHASE 3: COMPOSITE FRAME
  // ==========================================
  // Combine all strip snapshots into the final back buffer
  if not FTerminate then
  begin
    for i := 0 to FWorkerCount - 1 do
    begin
      if Assigned(FStripImages[i]) then
      begin
        var DestY := i * StripHeight;
        MainSurface.Canvas.DrawImage(FStripImages[i], 0, DestY, TSkSamplingOptions.High);
      end;
    end;

    // Update the shared back buffer
    FLock.Acquire;
    try
      FBackBuffer := MainSurface.MakeImageSnapshot;
    finally
      FLock.Release;
    end;

    // Request UI repaint
    ThreadSafeInvalidate;
  end;
end;

{------------------------------------------------------------------------------
  Draw
  Main Thread Execution. Draws the final back buffer to the screen.
------------------------------------------------------------------------------}
procedure TSkiaCustomMultiThreadedBase.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  ImageToDraw: ISkImage;
  CurrentTime: Double;
begin
  // Retrieve the latest frame from the buffer
  FLock.Acquire;
  try
    ImageToDraw := FBackBuffer;
  finally
    FLock.Release;
  end;

  if Assigned(ImageToDraw) then
  begin
    ACanvas.DrawImage(ImageToDraw, 0, 0, TSkSamplingOptions.High);

    // Calculate Real FPS
    Inc(FFrameCount);
    CurrentTime := FStopwatch.Elapsed.TotalMilliseconds;
    if (CurrentTime - FLastFpsTime) >= 1000 then
    begin
      FRealFPS := Round(FFrameCount / ((CurrentTime - FLastFpsTime) / 1000.0));
      FFrameCount := 0;
      FLastFpsTime := CurrentTime;
    end;
  end
  else
    ACanvas.Clear(TAlphaColors.Gray);
end;

{------------------------------------------------------------------------------
  Demo Logic & Rendering
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.UpdateLogic(const DeltaTime: Double);
begin
  // Move Box
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

  // Rotate
  FAngle := FAngle + (3.0 * DeltaTime);

  // Flag for redraw if state changed
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
  StripYOffset: Single;
begin
  // 1. Clear Background
  Paint := TSkPaint.Create;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.Color := TAlphaColors.Black;
  ACanvas.DrawRect(ADest, Paint);

  // 2. Draw Object
  if AIsActive then
  begin
    StripYOffset := ATime;

    // Calculate the object's position relative to this strip
    DrawRect := TRectF.Create(AObjectRect.Left, AObjectRect.Top - StripYOffset, AObjectRect.Right, AObjectRect.Bottom - StripYOffset);

    // Optimization: Cull if outside strip bounds
    if (DrawRect.Bottom < 0) or (DrawRect.Top > ADest.Height) then
      Exit;

    // Draw Red Box
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := $FFFF0000;
    Paint.AntiAlias := True;
    ACanvas.DrawRect(DrawRect, Paint);

    // Draw White Border
    Paint.Style := TSkPaintStyle.Stroke;
    Paint.StrokeWidth := 2;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawRect(DrawRect, Paint);
  end;
end;

end.
