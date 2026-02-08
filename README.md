# SkiaCustomMultiThreadedBase
A High-Performance, Multi-Threaded Rendering Skeleton for FMX &amp; Skia4Delphi Experimental v0.2 alpha
    

<img width="646" height="510" alt="Unbenannt" src="https://github.com/user-attachments/assets/decde0cd-65fa-49e3-bfbc-16233598a54b" />



         
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

***Multithreaded rendering at all works and looks ok now, no flicker at all (except when we do more than 4 threads, then some artifacts but still running even at 64), cause we wait a short moment (less than sleep(1)) after create each workerthread but we get memleak and fill up and die after a while...somebody see it maybe or has an idea?***     
    
On dual core no artifacts even at 64 threads, but getting a bit slow, still nice to test. Runs stable till mem full at 64 threads. Artifacts so think timing at faster pc   
    
Probably I don't see the Forrest cause of all the trees or something...   
    
i get now a bit to my limits here, someone with more than 1 month experience in skia4delphi maybe better should look at it
