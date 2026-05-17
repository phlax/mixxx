Build Mixxx in a clean Ubuntu 24.04 container without installing dependencies on your host:

```bash
docker build -t mixxx-build docker/build/
docker run --rm -v "$(pwd):/src" mixxx-build /src/docker/build/build.sh
```

After the build finishes, the binary is available at `./build/mixxx` on the host.
