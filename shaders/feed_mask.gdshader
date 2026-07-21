shader_type canvas_item;
// Masks the feed's own SubViewport output to a rounded rect, since FeedClip's
// clip_contents is rectangular-only and can't follow a non-rectangular cutout
// (e.g. a rounded phone screen). Applied on FeedContainer itself, so it clips
// regardless of what decoration sits on top. corner_radius is driven by
// frame_host.gd from the active FrameBase.feed_corner_radius. See design-doc.md §2.

uniform float corner_radius : hint_range(0.0, 500.0) = 0.0;

float rounded_rect_sdf(vec2 pos, vec2 half_size, float radius) {
	vec2 q = abs(pos) - half_size + radius;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	vec2 size = 1.0 / TEXTURE_PIXEL_SIZE;
	vec2 pos = UV * size - size * 0.5;
	float d = rounded_rect_sdf(pos, size * 0.5, corner_radius);
	vec4 tex = texture(TEXTURE, UV);
	tex.a *= 1.0 - smoothstep(-1.5, 1.5, d);
	COLOR = tex;
}
