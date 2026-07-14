extends Control

@export var artist_label: Label
@export var artwork_label: Label
@export var artwork: TextureRect

var _distort_material: ShaderMaterial


func _ready() -> void:
	if artwork and artwork.material is ShaderMaterial:
		# Materials are shared across scene instances by default — duplicate so
		# per-card distortion (jitter) doesn't drive every card at once.
		_distort_material = artwork.material.duplicate()
		artwork.material = _distort_material
	else:
		push_error("post_card.gd: ArtworkRect has no ShaderMaterial assigned in the editor")


func setup(artist: String, title: String, art: Texture2D) -> void:
	artist_label.text = artist
	artwork_label.text = title
	artwork.texture = art


func set_distortion(value: float) -> void:
	if _distort_material:
		_distort_material.set_shader_parameter("distortion", value)
