# Watch & Batch Transcode

A simple Docker container that watches a specified input directory for video files, automatically transcodes them using FFmpeg with configurable settings (specifically for single-pass CRF), moves files to success/failure directories, logs processing details to a CSV file, and can send notifications via [ntfy.sh](https://ntfy.sh/).

It is built on the [linuxserver.io FFmpeg base image](https://github.com/linuxserver/docker-ffmpeg), inheriting its user/group ID handling and S6-overlay init system.

## Features

* **Directory watch:** Continuously scans the input directory for new files
* **Automatic Processing:** Automatically picks up the first file found and starts processing
* **FFmpeg Transcoding:** Transcodes the file with FFmpeg 
* **Configurable Settings:** Easy configuration of video codec, CRF, encode preset, audio codec, and audio bitrate via environment variables
* **Retry Mechanism:** Retries multiple times before giving up
* **Success/failure classification:** Moves successfully processed files to the `completed` directory and failed files to the `failed` directory. When processing starts, original files are moved to the `sources_processed` directory
* **CSV Logging:** Appends processing details (filename, input size, output size, ratio, time taken) to a CSV file in the `completed` directory
* **NTFY Notifications:** Optional notifications via [ntfy.sh](https://ntfy.sh/) on success and failure. Supports custom NTFY server
* **Source Deletion:** Can be configured to automatically delete the original source file after success

## Getting Started

### Prerequisites

- [Docker](https://docs.docker.com/engine/install/) installed
- [Docker Compose](https://docs.docker.com/compose/install/) installed

### Setup

1. **Create a `docker-compose.yaml` file** using the template from the repo:
   ```bash
   curl -O https://raw.githubusercontent.com/ignis621/watch-batch-transcode/main/docker-compose.yaml
   ```

2. **Configure it** to suit your needs - volumes, environment variables, etc.

### Running with Docker Compose

1. **Run using the prebuilt Docker image:**
    ```bash
    docker-compose up -d
    ```
    This pulls the latest image from Docker Hub and starts the container in detached mode.

2. **Check logs:**
    ```bash
    docker-compose logs -f
    ```

3. **Stop the container:**
    ```bash
    docker-compose down
    ```

## Configuration

Configuration is done via environment variables set in the `docker-compose.yaml` file.

| Environment Variable     | Default Value     | Description |
| :----------------------- | :---------------- | :---------- |
| `PUID`<br>`PGID`         | `1000`<br>`1000`  | User ID and Group ID the container will run as. Important for file permissions on mounted volumes. Match this to your host UIDs. Get yours with `id -u` and `id -g` |
| `TZ`                     | `Etc/UTC`         | Timezone for correct timestamps in logs (eg. `Europe/Warsaw`, `America/New_York`, `Asia/Tokyo`). [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) |
| `VIDEO_CODEC`            | `libx265`         | FFmpeg video codec to use (eg. `libx265`, `libx264`). [List of codecs](https://ffmpeg.org/ffmpeg-codecs.html#Video-Encoders) |
| `VIDEO_CRF`              | `22`              | Constant Rate Factor for video quality. Lower value = higher quality/size. Sane range for `libx265` is 18-24 |
| `VIDEO_PRESET`           | `medium`          | Encoding preset (speed vs. compression efficiency). Options for `libx265`/`libx264`: `ultrafast`, `superfast`, `veryfast`, `faster`, `fast`, `medium`, `slow`, `slower`, `veryslow`, `placebo` |
| `AUDIO_CODEC`            | `libopus`         | FFmpeg audio codec to use (eg. `libopus`, `aac`, `ac3`) [List of codecs](https://ffmpeg.org/ffmpeg-codecs.html#Audio-Encoders)  |
| `AUDIO_BITRATE`          | `96k`             | Audio bitrate (eg. `96k`, `128k`, `192k`). |
| `FINAL_VIDEO_CONTAINER`  | `mp4`             | Specifies the final output video container format (eg. `mp4`, `mkv`, `webm`). Defaults to `mp4`. |
| `OVERRIDE_ENCODE_ARGS`   | *(None)*          | **Advanced:** Completely overrides the encoding arguments. Example: `-c:v libx264 -b:v 2000k -preset slow -c:a aac -b:a 128k`. If set, individual `VIDEO_CODEC`, `VIDEO_CRF`, etc. **are ignored**. |
| `OVERRIDE_REMUX_ARGS`    | *(None)*          | **Advanced:** Completely overrides the remuxing arguments. Only change if you know exactly what you're doing |
| `NTFY_TOPIC`             | *(None)*          | **Required for NTFY.** Your [ntfy.sh](https://ntfy.sh/) topic. Uncomment and replace with your topic. |
| `NTFY_SERVER`            | `https://ntfy.sh` | Custom [ntfy.sh](https://ntfy.sh/) server URL. Use this if you run your own instance. |
| `DELETE_AFTER`           | *(None)*          | Set to **any non-empty** value (eg. `1`, `true`) to delete the original source file from `/sources_processed` after successful transcoding. |

## Directory Structure

The container uses the following directory structure for file processing, mapped via Docker volumes:

* `/sources`: **Input Directory.** Place video files here for processing. The script will pick up the first file it finds.
* `/sources_processed`: **Working Directory.** Files are moved here from `/sources` before processing begins. They remain here by default after successful processing unless `DELETE_AFTER` is set.
* `/completed`: **Output Directory.** Successfully transcoded files (in the format specified by `FINAL_VIDEO_CONTAINER`) are placed here. The `.processed_files.csv` log is also stored in this directory.
* `/failed`: **Error Directory.** Original files that failed all attempts are moved here.
* `/tmp`: **Temporary Directory.** Used for intermediate files during transcoding. Explicitly mapping this is a good idea for extremely big files, or if /tmp on the host is on a faster drive than your other data volumes.

## How it Works

1.  Script scans the `/sources` directory.
2.  If a file is found, it makes sure its not still being written or moved. If not ready, it waits and rechecks.
3.  Once ready, the file is moved to `/sources_processed`.
4.  FFmpeg attempts to transcode the file from `/sources_processed` to an MKV file in `/tmp` using parameters from environment variables (`OVERRIDE_ENCODE_ARGS` or `VIDEO_CODEC`, `VIDEO_CRF`, etc.)
5.  If encoding is successful, FFmpeg tries to remux the MKV to the final output file (eg. MP4) in `/completed` using remuxing parameters (`OVERRIDE_REMUX_ARGS` or default copy options).
6.  If both encoding and remuxing are successful:
    * The temporary MKV file is deleted
    * Processing time and file size details are calculated
    * An entry is appended to the `.processed_files.csv` file in `/completed`
    * If ntfy is configured, a success notification is sent
    * If `DELETE_AFTER` is set, the original file is deleted from `/sources_processed`
7.  If *either* encoding or remuxing fails after `MAX_RETRIES` attempts:
    * Any temp files are cleaned up
    * The original file is moved from `/sources_processed` to `/failed`
    * If ntfy is configured, a failure notification is sent
8. ~~Rinse~~ Wait and repeat

## CSV Log File (`.processed_files.csv`)

A CSV file named `.processed_files.csv` is created in the `/completed` dir if it doesn't exist. Each time a file is successfully processed, a new row is appended.

| Column                  | Description                                                                            |
| :---------------------- | :------------------------------------------------------------------------------------- |
| `filename`              | Original filename (escaped for csv)                                                    |
| `input_size_bytes`      | Size of the original source file in bytes                                              |
| `output_size_bytes`     | Size of the final MP4 file in bytes                                                    |
| `ratio`                 | Ratio of `output_size_bytes` to `input_size_bytes` (eg. 0.50 means 50% reduction).     |
| `processing_time_HHMMSS`| Total time to transcode this file (HH:MM:SS format)                                    |

## NTFY Notifications

To receive notifications on your phone or other devices via [ntfy.sh](https://ntfy.sh/):

1.  Get a topic name (either from the public instance or your own server).
2.  Set the `NTFY_TOPIC` environment variable in your `docker-compose.yaml` to this topic name.
3.  (Optional) If using a custom NTFY server, set the `NTFY_SERVER` environment variable to its address.

Success and fail messages will be sent to your specified topic.

## Building the Container

If you want to build the image yourself instead of pulling from Docker Hub:

1. **Clone the repository:**
    ```bash
    git clone https://github.com/ignis621/watch-batch-transcode
    cd watch-batch-transcode
    ```

2. **Build and run using the provided build config:**
    ```bash
    docker-compose -f docker-compose.build.yaml up -d --build
    ```

3. **Stop the container:**
    ```bash
    docker-compose -f docker-compose.build.yaml down
    ```

## Contributing

Contributions are welcome! Feel free to open issues for bugs or feature requests, or submit PRs

## License

This project is licensed under the GNU General Public License v3 (GPL-3). Check [tl;drLegal](https://www.tldrlegal.com/license/gnu-general-public-license-v3-gpl-3) for an explanation or [LICENSE](LICENSE) if you're rlly bored.

## Acknowledgements

* Uses the [FFmpeg](https://ffmpeg.org/) multimedia framework
* Built on [linuxserver.io FFmpeg Docker base image](https://github.com/linuxserver/docker-ffmpeg)
* Uses [ntfy.sh](https://ntfy.sh/) for simple push notifications
