dart-proxy
==========

Elphi Proxy Server, written in Dart

* Mostly follows Elphi smart plug protocol (no public spec yet)
* Handles 100 req/s fairly well, but once you introduce delays into plug responses you start seeing json parse issues- presumably the incoming tcp data is being buffered and is not being split properly (as with node.js).
* Check out elphicloud.com to see the hardware!