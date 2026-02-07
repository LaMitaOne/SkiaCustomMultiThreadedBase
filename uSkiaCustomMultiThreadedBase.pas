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
{ SkiaCustomMultiThreadedBase v0.2                                             }
{ by The Developer                                                             }
{                                                                              }
{------------------------------------------------------------------------------}
{
  Latest Changes:
   v 0.2:
   - Now we run each render strip in single workerthread
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
  System.Skia, System.Diagnostics, System.TimeSpan
  {$IFDEF MSWINDOWS}
    , WinApi.Windows
  {$ENDIF};

type
  TSkiaCustomMultiThreadedBase = class(TSkCustomControl)
  private
    { Threading & Sync }
    FRenderThreads: TList;
    FLock: TCriticalSection;
    FEvent: TEvent;
    FTargetFPS: Integer;
    FTerminate: Boolean;
    FStopwatch: TStopwatch;
    FFrameTime: Double;

    { CPU Affinity }
    FThreadAffinity: Integer;

    { Rendering }
    FBackBuffer: ISkImage;
    FStripImages: array of ISkImage;    // Stores finished snapshots
    FBackSurfaces: array of ISkSurface; // Temp surfaces for workers

    FFrameCount: Integer;
    FLastFpsTime: Double;
    FRealFPS: Integer;

    { Logic }
    FNeedsRedraw: Boolean;
    FActive: Boolean;
    FWorkerCount: Integer;
    FStripsCompleted: Integer;

    { Demo State }
    FDemoRect: TRectF;
    FDemoVelocity: TPointF;
    FAngle: Single;
    FPrevRect: TRectF;
    FPrevActive: Boolean;

    { Setters }
    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);
    procedure SetWorkerCount(const Value: Integer);
    procedure SetThreadAffinity(const Value: Integer);

    { Internal }
    procedure ThreadSafeInvalidate;
    procedure StartRenderThreads;
    procedure StopRenderLoop;
    procedure RenderFrame;
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
  Internal Record
==============================================================================}

type
  PWorkerTask = ^TWorkerTask;

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

  FTargetFPS := 60;
  FWorkerCount := 4;
  FRealFPS := 0;
  FLastFpsTime := 0;
  FStripsCompleted := 0;
  FThreadAffinity := -1;

  SetBounds(0, 0, 300, 200);
  HitTest := True;

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
  FNeedsRedraw := True;
  SetLength(FStripImages, 0);
  SetLength(FBackSurfaces, 0);
end;

{------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.SetWorkerCount(const Value: Integer);
begin
  if FWorkerCount <> Value then
  begin
    if FActive then
    begin
      Active := False;
      FWorkerCount := Value;
      Active := True;
    end
    else
      FWorkerCount := Value;
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
      Active := True;
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

{------------------------------------------------------------------------------}

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

        EndTime := FStopwatch.Elapsed.TotalMilliseconds;
        ElapsedMs := EndTime - StartTime;

        if FTargetFPS > 0 then
          FFrameTime := 1000.0 / FTargetFPS
        else
          FFrameTime := 0.016;

        SleepTime := Round(FFrameTime - ElapsedMs);
        if SleepTime < 0 then
          SleepTime := 0; // If we are slow, don't sleep
        if SleepTime > 0 then
          Sleep(SleepTime); // Only sleep if we are fast

        StartTime := StartTime + FFrameTime;
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
  CORE RENDERING
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

  // 1. Update Logic
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

  // 2. Capture State
  CurrentRect := FDemoRect;
  CurrentActive := FActive;
  CurrentAngle := FAngle;

  // 3. Setup
  TotalHeight := Round(Height);
  StripHeight := TotalHeight div FWorkerCount;
  if (TotalHeight mod FWorkerCount) <> 0 then
    StripHeight := StripHeight + 1;

  SetLength(RunningThreads, FWorkerCount);
  if Length(FBackSurfaces) <> FWorkerCount then
    SetLength(FBackSurfaces, FWorkerCount);
  if Length(FStripImages) <> FWorkerCount then
    SetLength(FStripImages, FWorkerCount);

  MainSurface := TSkSurface.MakeRaster(Round(Width), TotalHeight);
  if not Assigned(MainSurface) then
    Exit;

  FStripsCompleted := 0;
  FEvent.ResetEvent;

  // ==========================================
  // PHASE 1: SPAWN & START (Staggered)
  // ==========================================
  for i := 0 to FWorkerCount - 1 do
  begin
    var StripY := i * StripHeight;
    var CurrentH := StripHeight;
    var LIndex: Integer := i;

    if LIndex = FWorkerCount - 1 then
      CurrentH := TotalHeight - StripY;

    if CurrentH <= 0 then
    begin
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

    // Create Surface
    FBackSurfaces[LIndex] := TSkSurface.MakeRaster(Round(Width), CurrentH);
    if not Assigned(FBackSurfaces[LIndex]) then
      Continue;

    // Clear Background
    FBackSurfaces[LIndex].Canvas.Clear(TAlphaColors.Black);

    // Prepare Task
    WorkerTask.Owner := Self;
    WorkerTask.StripIndex := LIndex;
    WorkerTask.StripY := StripY;
    WorkerTask.StripHeight := CurrentH;
    WorkerTask.ObjRect := CurrentRect;
    WorkerTask.Angle := CurrentAngle;
    WorkerTask.IsActive := CurrentActive;

    var LSurface: ISkSurface := FBackSurfaces[LIndex];

    // Start Thread
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
        Task := WorkerTask;
        Surface := LSurface;

        if not Assigned(Task.Owner) then
          Exit;

        try
          if not Assigned(Surface) then
            raise Exception.Create('Surface nil');

          // Affinity
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

          // --- RENDER TO SURFACE ---
          LCanvas := Surface.Canvas;
          LCanvas.Save;
          try
            Task.Owner.RenderStrip(LCanvas, TRectF.Create(0, 0, Task.Owner.Width, Task.StripHeight), Task.StripY, Task.StripIndex, Task.ObjRect, Task.Angle, Task.IsActive);
          finally
            LCanvas.Restore;
          end;

          // --- CREATE SNAPSHOT ---
          Snapshot := Surface.MakeImageSnapshot;
          Task.Owner.FStripImages[Task.StripIndex] := Snapshot;

        finally
          // Signal Done
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
    // THE STAGGER (Micro-Delay else we flicker)
    // ==========================================
    if LIndex < FWorkerCount - 1 then
    begin
      if LIndex = 0 then
        sleep(1)
      else    //try to sleep here less than sleep(1)
        for var j := 0 to 300 do
          SwitchToThread;
    end;
  end;

  // ==========================================
  // PHASE 2: WAIT
  // ==========================================
  while FStripsCompleted < FWorkerCount do
  begin
    if FTerminate then
      Break;
    FEvent.WaitFor(INFINITE);
  end;

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
  // PHASE 3: COMPOSITE (From Snapshots)
  // ==========================================
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

    FLock.Acquire;
    try
      FBackBuffer := MainSurface.MakeImageSnapshot;
    finally
      FLock.Release;
    end;

    ThreadSafeInvalidate;
  end;
end;

{------------------------------------------------------------------------------
  Main Thread Drawing
------------------------------------------------------------------------------}

procedure TSkiaCustomMultiThreadedBase.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  ImageToDraw: ISkImage;
  CurrentTime: Double;
begin
  FLock.Acquire;
  try
    ImageToDraw := FBackBuffer;
  finally
    FLock.Release;
  end;

  if Assigned(ImageToDraw) then
  begin
    ACanvas.DrawImage(ImageToDraw, 0, 0, TSkSamplingOptions.High);

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
  FDemoRect.Offset(FDemoVelocity.X * DeltaTime, FDemoVelocity.Y * DeltaTime);

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

  FAngle := FAngle + (3.0 * DeltaTime);

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
  // 1. Draw Background (Already cleared to Black in Main Thread, but we ensure it)
  // Optional: If you want transparency, don't clear here.
  Paint := TSkPaint.Create;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.Color := TAlphaColors.Black;
  ACanvas.DrawRect(ADest, Paint);

  // 2. Draw Object
  if AIsActive then
  begin
    StripYOffset := ATime;

    // Calculate local rect for this strip
    DrawRect := TRectF.Create(AObjectRect.Left, AObjectRect.Top - StripYOffset, AObjectRect.Right, AObjectRect.Bottom - StripYOffset);

    // Optimization: Don't draw if outside
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

