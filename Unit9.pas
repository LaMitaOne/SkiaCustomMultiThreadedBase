unit Unit9;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.Layouts,
  FMX.StdCtrls, FMX.Controls.Presentation, FMX.ExtCtrls, FMX.ListBox, 
  uSkiaCustomMultiThreadedBase;

type
  TForm9 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    { Private-Deklarationen }
    FSkiaView: TSkiaCustomMultiThreadedBase;
    btnStart: TButton;
    btnStop: TButton;
    tbFPS: TTrackBar;
    lblFPS: TLabel;
    FPSTimer: TTimer;
    cbWorkerCount: TComboBox; 
    procedure OnStartClick(Sender: TObject);
    procedure OnStopClick(Sender: TObject);
    procedure OnFPSTracking(Sender: TObject);
    procedure OnFPSTimer(Sender: TObject);
    procedure OnWorkerCountChange(Sender: TObject);
  public
    { Public-Deklarationen }
  end;

var
  Form9: TForm9;

implementation
{$R *.fmx}

procedure TForm9.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  // 1. Create the Custom Skia Component
  FSkiaView := TSkiaCustomMultiThreadedBase.Create(Self);
  FSkiaView.Parent := Self;
  FSkiaView.Align := TAlignLayout.Client;
  FSkiaView.Margins.Rect := TRectF.Create(10, 110, 10, 10); 
  FSkiaView.HitTest := False;
  FSkiaView.Active := False;
  FSkiaView.TargetFPS := 60;
  // 2. Create Start Button
  btnStart := TButton.Create(Self);
  btnStart.Parent := Self;
  btnStart.Text := 'Start Animation';
  btnStart.Width := 100;
  btnStart.Height := 30;
  btnStart.Position.X := 20;
  btnStart.Position.Y := 20;
  btnStart.OnClick := OnStartClick;
  // 3. Create Stop Button
  btnStop := TButton.Create(Self);
  btnStop.Parent := Self;
  btnStop.Text := 'Stop Animation';
  btnStop.Width := 100;
  btnStop.Height := 30;
  btnStop.Position.X := 130;
  btnStop.Position.Y := 20;
  btnStop.OnClick := OnStopClick;
  // 4. Create FPS Label
  lblFPS := TLabel.Create(Self);
  lblFPS.Parent := Self;
  lblFPS.Text := 'Target: 60 | Real: 0 FPS';
  lblFPS.Position.X := 300;
  lblFPS.Position.Y := 30;
  lblFPS.Width := 200;
  lblFPS.Height := 20;
  lblFPS.Font.Size := 14;
  // 5. Create FPS TrackBar
  tbFPS := TTrackBar.Create(Self);
  tbFPS.Parent := Self;
  tbFPS.Min := 1;
  tbFPS.Max := 240;
  tbFPS.Value := 60;
  tbFPS.Width := 200;
  tbFPS.Position.X := 300;
  tbFPS.Position.Y := 50;
  tbFPS.OnTracking := OnFPSTracking;
  // 6. Create Worker Count Label
  var lblWorkers := TLabel.Create(Self);
  lblWorkers.Parent := Self;
  lblWorkers.Text := 'Threads:';
  lblWorkers.Position.X := 20;
  lblWorkers.Position.Y := 60;
  lblWorkers.Width := 60;
  // 7. Create Worker Count ComboBox
  cbWorkerCount := TComboBox.Create(Self);
  cbWorkerCount.Parent := Self;
  cbWorkerCount.Width := 155;
  cbWorkerCount.Position.X := 80;
  cbWorkerCount.Position.Y := 60;
  cbWorkerCount.ItemHeight := 25; 
  // Fill ComboBox with 1 to 16
  cbWorkerCount.Items.Add('each line a thread');
  for i := 1 to 64 do
    cbWorkerCount.Items.Add(IntToStr(i));
  cbWorkerCount.ItemIndex := 4; // Default to 4
  cbWorkerCount.OnChange := OnWorkerCountChange;
  // 8. Create FPS Update Timer
  FPSTimer := TTimer.Create(Self);
  FPSTimer.Interval := 1000; // 1 Second for accurate reading
  FPSTimer.OnTimer := OnFPSTimer;
  FPSTimer.Enabled := True;
end;

procedure TForm9.FormDestroy(Sender: TObject);
begin
  // Components are owned by the form, auto-freed
end;

procedure TForm9.OnStartClick(Sender: TObject);
begin
  if Assigned(FSkiaView) then
    FSkiaView.Active := True;
end;

procedure TForm9.OnStopClick(Sender: TObject);
begin
  if Assigned(FSkiaView) then
    FSkiaView.Active := False;
end;

procedure TForm9.OnFPSTracking(Sender: TObject);
begin
  if Assigned(FSkiaView) and Assigned(tbFPS) then
  begin
    FSkiaView.TargetFPS := Round(tbFPS.Value);
  end;
end;

procedure TForm9.OnFPSTimer(Sender: TObject);
begin
  if Assigned(FSkiaView) and Assigned(lblFPS) then
  begin
    lblFPS.Text := Format('Target: %d | Real: %d FPS', [FSkiaView.TargetFPS, FSkiaView.RealFPS]);
  end;
end;

procedure TForm9.OnWorkerCountChange(Sender: TObject);
var
  NewCount: Integer;
begin
  if Assigned(FSkiaView) and Assigned(cbWorkerCount) then
  begin
    if cbWorkerCount.ItemIndex = 0 then
      NewCount := Height
    else if cbWorkerCount.ItemIndex <> -1 then
    begin
      NewCount := StrToIntDef(cbWorkerCount.Items[cbWorkerCount.ItemIndex], 4);
    end;
    FSkiaView.WorkerCount := NewCount;
  end;
end;

end.



