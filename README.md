# Video Scan

## Install
```sh
curl -O https://raw.githubusercontent.com/dipodidae/video-scan/main/scan.sh && chmod +x scan.sh
```

## How to use

```sh
./scan.sh folder/to/videofiles
```

# Deface

##install

```sh
curl -O https://raw.githubusercontent.com/dipodidae/video-scan/main/deface.sh && chmod +x deface.sh
```

```sh
./deface.sh folder/to/videofiles
```

- Works best when you run it on a folder that's on your hard drive, not a thumb drive or an sd card
  - This is because it will create a folder called `_output` and put the defaced videos in there
  - This might exceed the capacity of your thumb drive or sd card
- It will create a folder called `_output` and put the defaced videos in there
- You don't have to put the script in the folder you want to deface, you can put it anywhere and just point it to the folder you want to deface
- Run it by typing `./deface.sh folder/to/videofiles`
- It's best to point to the absolute path of the folder you want to deface, like `deface.sh /home/username/folder/to/videofiles`
- Good luck
