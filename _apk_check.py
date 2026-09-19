import zipfile, os

apk = r"build\app\outputs\flutter-apk\app-release.apk"
print("APK: %.1f MB" % (os.path.getsize(apk)/1024/1024))
z = zipfile.ZipFile(apk)
targets = [n for n in z.namelist() if n.endswith("libapp.so")]

keys = {
    "amap_web":  b"8357e50a77e9d3d75965b4db54a40936",
    "amap_and":  b"f89c403d22831043c82d42b19dcea4ab",
    "qw_key":    b"fa416837d5cf4160bc80ad925e1a8a8a",
    "qw_host":   b"kn6aq2bj2h.re.qweatherapi.com",
}
for n in targets:
    data = z.read(n)
    print("--- %s (%.1f MB)" % (n, len(data)/1024/1024))
    for label, needle in keys.items():
        print("    %-9s : %s" % (label, "FOUND" if data.find(needle) >= 0 else "MISSING"))
z.close()
