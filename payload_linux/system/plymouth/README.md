The plymouth boot theme `install.sh` puts under `/usr/share/plymouth/themes/autobleem/`.

`splash.png` is the picture: 1920x1080 (the design's `plymouth-1080.png`; the script shows it 1:1 at 1080p and scales it
down to fit a smaller mode, black around it - it never scales up). The installer skips the boot splash, with a warning, if the
file is missing from the package.
