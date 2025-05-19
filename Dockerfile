FROM lscr.io/linuxserver/ffmpeg:amd64-7.1.1

WORKDIR /app

RUN apt-get update && \
    apt-get install -y lsof && \
    rm -rf /var/lib/apt/lists/*

COPY process_videos.sh .

RUN chmod +x ./process_videos.sh

ENTRYPOINT ["/app/process_videos.sh"]
