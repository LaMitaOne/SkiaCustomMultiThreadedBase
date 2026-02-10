# SkiaCustomMultiThreadedBase
A High-Performance, Multi-Threaded Rendering Skeleton for FMX &amp; Skia4Delphi Experimental v0.3 alpha
    
<img width="639" height="506" alt="Unbenannt" src="https://github.com/user-attachments/assets/275211ac-4b01-4dc9-a702-a265371702c7" />


         
This is a minimal, abstracted rendering engine designed to solve the Main-Thread Bottleneck in FireMonkey (FMX) applications.     
It moves all heavy rendering logic (drawing images, effects, particles) to a background thread pool, while the main UI thread simply displays the finished image.    

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SkiaCustomMultiThreadedBase)
    
⚡ Key Features     
    
     Multi-Threaded Architecture: Spawns configurable worker threads.    
     Double Buffering: Renders to an off-screen surface to prevent flickering/tearing.    
     Strip Rendering: Divides the screen into horizontal strips to parallelize workload.    
     Non-Blocking UI: The main thread remains responsive even under heavy load.      
     
 
⚠️ Experimental Status    
     
This unit is experimental. Just an idea i got while implementing doublebuffering and thought of how miniled split screen in regions...    
    
***Multithreaded rendering works and looks ok now, no flicker, real and target fps get same at 120Hz, 144Hz not anymore - around 128fps then, 256 threads only get 20fps here at ryzen 7 5800x***     
   
we running stable now so far, no big memleak anymore, but a little...anyway...now i go sleep a few days better :P   
   
oh and yes ...i tried it really...256 threads on Asus zenbook dualcore lol he survived and done 13fps still oO impressive compared to the ryzen...  
     
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
