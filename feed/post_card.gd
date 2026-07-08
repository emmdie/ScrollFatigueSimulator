extends Control

@export var artist_label: Label
@export var artwork_label: Label
@export var artwork: TextureRect

var _distort_material: ShaderMaterial


func _ready() -> void:
	if artwork and artwork.material is ShaderMaterial:
		_distort_material = artwork.material
	else:
		push_error("post_card.gd: ArtworkRect has no ShaderMaterial assigned in the editor")


func setup(artist: String, title: String, art: Texture2D) -> void:
	artist_label.text = artist
	artwork_label.text = title
	artwork.texture = art


func set_distortion(value: float) -> void:
	if _distort_material:
		_distort_material.set_shader_parameter("distortion", value)
