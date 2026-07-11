class_name HoroscopeClient
extends RefCounted
## Validates an ArtworkData dict (content manifest schema, §1) and hands it to
## ExternalBridge, which builds the CLI flags itself. No state, no signals —
## printing_overlay listens to ExternalBridge.horoscope_ready directly.


static func request(artwork_data: Dictionary) -> void:
	if artwork_data.is_empty():
		push_warning("HoroscopeClient.request(): empty artwork_data — skipping horoscope request.")
		return
	for key in ["title", "artist", "tags"]:
		if not artwork_data.has(key):
			push_warning("HoroscopeClient.request(): artwork_data missing '%s' — prompt will be degraded." % key)
	# Pass the dict through untouched: it also carries `date`, `id` and
	# `_resolved_path` (used for print_job.py's --image), plus any pass-through
	# manifest keys. Rebuilding a partial dict here would silently drop them.
	ExternalBridge.request_horoscope(artwork_data)
