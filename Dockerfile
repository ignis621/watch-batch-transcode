FROM lscr.io/linuxserver/ffmpeg:amd64-7.1.1

WORKDIR /app

COPY process_videos.sh .

RUN chmod +x ./process_videos.sh

# ENTRYPOINT ["/bin/bash", "/app/process_videos.sh"]
CMD ["/app/process_videos.sh"]
