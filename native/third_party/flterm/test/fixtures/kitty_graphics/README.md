# Kitty graphics test fixtures

`test_image.png` is a 64x64 photograph fetched from https://picsum.photos
(seed `flterm-kitty`), which serves images under the Unsplash License:
free to use for any commercial or personal project, no attribution
required, cannot be sold unaltered. The fixture exercises the PNG
decoder + kitty storage + cache + painter pipeline end to end with real
photographic data (gradients, compression artifacts, non-trivial color
distribution) rather than a synthetic test pattern.
