# My personal MPV configuration 
<img width="1920" height="1080" alt="Rick and Morty S05E03 mp4-00 10 11 402-#1" src="https://github.com/user-attachments/assets/91b824ea-f5b2-4528-912b-a423c750da66" />

<img width="1920" height="1080" alt="Rick and Morty S05E03 mp4-00 07 53 056-#2" src="https://github.com/user-attachments/assets/7ce0ce28-fb20-4a15-b23e-fcec0a56b77f" />

---

## Installation (Windows)
* Download the latest 64bit `mpv-x86_64-gcc-*.7z` (or 64bit-v3 for newer CPUs `mpv-x86_64-v3-*.7z`) mpv Windows build by shinchiro [here](https://mpv.io/installation/) or directly from [here](https://github.com/shinchiro/mpv-winbuild-cmake/releases) and extract its contents into a folder of your choice. This is now your mpv folder and can be placed wherever you want. Make sure to put it in a place you won't move it from or delete. 
* Run `mpv-install.bat`, which is located in the `installer` folder, with administrator privileges by right-clicking and selecting run as administrator, after it's done, you'll get a prompt to open Control Panel and set mpv as the default player.
* [Download](https://github.com/HongYue1/mpv-config/archive/refs/heads/main.zip) and extract the `portable_config` folder from this repo to the mpv folder you just made, beside the `mpv.exe`.
* For mpv updates, right click updater.bat and run as administrator, then follow the instructions. There will be an option to install yt-dlp to be able to stream YouTube videos and any other websites supported by [yt-dlp,](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md) if you want. Once the initial run of updater.bat has completed a settings.xml file will be generated to save your preferences. 
* You're all set up. Go watch some videos!

## Installation (Linux/Mac OS)
- Install mpv using your package manager depending on your distro. Ubuntu: `sudo dnf install mpv` | Archlinux `sudo pacman -S mpv` or `yay -S mpv-git`, etc...
- [Download](https://github.com/HongYue1/mpv-config/archive/refs/heads/main.zip) this repo and extract it. Copy the content inside the `portable_config` folder to `~/.config/mpv/` create it if it doesn't exist.
- Or you can do it automatically using `git` if you have it installed:

```sh
git clone https://github.com/HongYue1/mpv-config.git && mkdir -p ~/.config/mpv && mv ./mpv-config/portable_config/* ~/.config/mpv/ && rm -rf mpv-config
```
- The config should be installed now.

---

## Defaults you may need to edit if you need to:
- use the official documentation if there is an option you don't understand search with `ctrl+f`: https://mpv.io/manual/master/
- By default I use vulkan as a gpu-api and hwdec, if your gpu doesn't support vulkan or if you have have an issue with it.
  - `mpv.conf:line 49` : `gpu-api=vulkan` could be set to `auto` `d3d11` or `opengl`
  - `mpv.conf:line 51` : `hwdec=vulkan`   could be set to `auto` `auto-copy` `auto-safe` or options from [here](https://mpv.io/manual/master/#options-gpu-api)
  - `profiles.conf:line 5` : `glsl-shader="~~/shaders/CuNNy/ds/dp4a/CuNNy-4x16-DS-Q.glsl"` either delete this line or use another shader as a default since this shader requries vulkan.
- By default I have my configuration downmixes 7.1/5.1 to stereo 2.0. if you have a surround system then you and don't want the audio to be downmixed delete these two lines:
  - `profiles.conf:line 69` : `profile-cond=(p["audio-params/channel-count"] == 6)`
  - `profiles.conf:line 75` : `profile-cond=(p["audio-params/channel-count"] == 8)`
 
- If you don't have a calibrated icc being used in windows or if you have issues with color in video delete this line:
  - `mpv.conf:line 63` : `icc-profile-auto`    
- video output range is set to `full` by default but if you are using a TV for example that only supported limited range then change this line:
  - `mpv.conf:line 73` : `video-output-levels=full` to `video-output-levels=limited` or simply put it on auto `video-output-levels=auto`
- By default youtube playback will choose `1080p` or less if it's not available by default, you can change that in this line:
  - `mpv.conf:line 89` : `ytdl-format=bestvideo[height<=?1080]+bestaudio/best[height<=?1080]` change the `1080` to whatever you like.    
- dither depth needs to be set to your screen bit depth by default it's `10` bit. if you don't know your screen bit depth, on windows go to `settings> system> display> advanced display`.
  - `mpv.conf:line 53` : `dither-depth=10` set it to your screen bit depth. if you use `gpu-api=d3d11` then you can simply set it to `auto`
  - Note that the on-the-wire bit depth cannot be detected except when using gpu-api=d3d11. Explicitly setting the value to your display's bit depth is recommended, as dithering performed by some LCD panels can be of low quality.
- Default shaders for SD and HD+ content can be changed in the `profiles.conf`

---

## Important Notes:
- when first time launching MPV after installing the configuration or using a shader for the first time, MPV may hang for a few seconds because it's create shader cache. it should happen only in the first time and will be fast afterwards unless cache is deleted then MPV would need to create it again the next time it launches or use a new shader.
- If the UI feels sluggish/slow while playing video, you can remedy this a bit by placing this in your `mpv.conf`:
`video-sync=display-resample`
Though this does come at the cost of a little bit higher CPU/GPU load.
What is going on?
uosc places performance as one of its top priorities, but it might feel a bit sluggish because during a video playback, the UI rendering frequency is chained to its frame rate. To test this, you can pause the video which will switch refresh rate to be closer or match the frequency of your monitor, and the UI should feel smoother. This is mpv limitation, and not much we can do about it on our side.
- press `tab` to toggle UI hiding or always showing.
- To see available keybindings or to edit them look in the `input.conf`.
---

## Scripts used:
- [uosc](https://github.com/darsain/uosc) - Adds a minimalist but highly customisable GUI.
- [evafast](https://github.com/po5/evafast) - Fast-forwarding and seeking on a single key.
- [thumbfast](https://github.com/po5/thumbfast) - High-performance on-the-fly thumbnailer.
- [memo](https://github.com/po5/memo) - A recent files/history menu for mpv with optional uosc integration.
- [quality-menu](https://github.com/natural-harmonia-gropius/mpv-quality-menu) - A userscript for MPV that allows you to change the streamed video and audio quality (ytdl-format) on the fly.
- [mpv-reload](https://github.com/4e6/mpv-reload) - mpv plugin for automatic reloading of slow/stuck video streams
- [mpv-ytsub](https://github.com/Idlusen/mpv-ytsub) - lua script for mpv to load youtube automatic captions
- [mpv_sponsorblock_minimal](https://codeberg.org/jouni/mpv_sponsorblock_minimal) - skips sponsorblock

---

  ## Shaders included:
* [ACNet](https://github.com/TianZerL/ACNetGLSL)
* [Ani4Kv2 and AniSD](https://github.com/Sirosky/Upscale-Hub)
* [ArtCNN](https://github.com/Artoriuz/ArtCNN)
* [Anime4K](https://github.com/bloc97/Anime4K/tree/master/glsl)
* [AMD CAS, FSR and NVScaler](https://gist.github.com/agyild)
* [CfL_Prediction](https://github.com/Artoriuz/glsl-chroma-from-luma-prediction)
* [CuNNy](https://github.com/funnyplanter/CuNNy)
* [FSRCNNX](https://github.com/igv/FSRCNN-TensorFlow/releases)
* [Filmgrain](https://github.com/haasn/gentoo-conf/tree/xor/home/nand/.mpv/shaders)
* [hdeband and nlmeans](https://github.com/AN3223/dotfiles/tree/master/.config/mpv/shaders)
* [JointBilateral and FastBilateral](https://github.com/Artoriuz/glsl-joint-bilateral)
* [KrigBilateral and adaptive-sharpen](https://gist.github.com/igv)
* [NNEDI3 and RAVU](https://github.com/bjin/mpv-prescalers/)

---

## Repos I have used as a reference:
- https://github.com/tuilakhanh/mpv-config
- https://github.com/Zabooby/mpv-config/
- https://github.com/Tsubajashi/mpv-settings
- https://github.com/classicjazz/mpv-config/
- https://github.com/wopian/mpv-config/
- https://github.com/Katzenwerfer/mpv-config/
- https://github.com/itsmeipg/mpv-config/
- https://github.com/noelsimbolon/mpv-config/
- https://github.com/zydezu/mpvconfig/

   
