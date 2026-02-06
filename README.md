# SkiaCustomMultiThreadedBase
A High-Performance, Multi-Threaded Rendering Skeleton for FMX &amp; Skia4Delphi Experimental v0.1 alpha
    
<img width="647" height="514" alt="Unbenannt" src="https://github.com/user-attachments/assets/fd01f4a5-19ea-4bae-ba73-218451c042aa" />

         
This is a minimal, abstracted rendering engine designed to solve the Main-Thread Bottleneck in FireMonkey (FMX) applications.     
It moves all heavy rendering logic (drawing images, effects, particles) to a background thread pool, while the main UI thread simply displays the finished image.    
    
⚡ Key Features     
    
     Multi-Threaded Architecture: Spawns configurable worker threads.    
     Double Buffering: Renders to an off-screen surface to prevent flickering/tearing.    
     Strip Rendering: Divides the screen into horizontal strips to parallelize workload.    
     Non-Blocking UI: The main thread remains responsive (100ms touch response) even under heavy load.      
     
    
🧠 How It Works     
    
    Background Thread: Runs logic and draws strips sequentially to a shared off-screen surface.     
    Synchronization: Uses TCriticalSection and TEvent for thread-safe buffer swapping.     
    Main Thread: Takes the completed snapshot and draws it to the screen (TSkCustomControl.Draw).     
     
    
 
⚠️ Experimental Status    
    
This unit is experimental. Just an idea i got while implementing doublebuffering    
