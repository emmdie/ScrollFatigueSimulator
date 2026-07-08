extends Control

@export var artist_label: Label
@export var artwork_label: Label
@export var artwork: TextureRect
@export var distort_group: CanvasGroup

var _distort_material: ShaderMaterial


func _ready() -> void:
	if distort_group:
		_distort_material = ShaderMaterial.new()
		_distort_material.shader = load("res://shaders/image_distort.gdshader")
		distort_group.material = _distort_material


func setup(artist: String, title: String, art: Texture2D) -> void:
	artist_label.text = artist
	artwork_label.text = title
	artwork.texture = art


func set_distortion(value: float) -> void:
	if _distort_material:
		_distort_material.set_shader_parameter("distortion", value)
