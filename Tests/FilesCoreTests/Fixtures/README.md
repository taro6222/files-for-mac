# Archive test fixtures

The 7z and RAR samples are decoded copies of the uuencoded reference files from the
[libarchive test suite](https://github.com/libarchive/libarchive/tree/master/libarchive/test):

- `test_read_format_7zip_empty_file.7z.uu` → `libarchive-empty.7z`
- `test_read_format_rar_noeof.rar.uu` → `libarchive-noeof.rar`

They retain the upstream libarchive project's BSD-2-Clause licensing context and are
used only to verify the system libarchive reader and the application's safe extraction path.
