class_name HoroscopeClient
extends RefCounted
## Builds an ArtworkData dict (content manifest schema, §1) into the call
## ExternalBridge expects. No state, no signals — printing_overlay listens
## to ExternalBridge.horoscope_ready directly.


static func request(artwork_data: Dictionary) -> void:
	var title: String = artwork_data.get("title", "")
	var artist: String = artwork_data.get("artist", "")
	var date: String = artwork_data.get("date", "")
	var tags: Array = artwork_data.get("tags", [])
	var tags_csv: String = ",".join(tags)
	ExternalBridge.request_horoscope(title, artist, date, tags_csv)
