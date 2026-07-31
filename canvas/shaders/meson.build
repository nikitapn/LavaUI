# Shader compilation — outputs land in <builddir>/shaders/ matching the
# relative paths the application uses at runtime (e.g. "shaders/mesh.vert.bin").

fs = import('fs')
glslc = find_program('glslc')

shader_sources = [
  meson.project_source_root() / 'src/shaders/2d/shader.vert',
  meson.project_source_root() / 'src/shaders/2d/shader.frag',
  meson.project_source_root() / 'src/shaders/2d/quad.vert',
  meson.project_source_root() / 'src/shaders/2d/quad.frag',
  meson.project_source_root() / 'src/shaders/2d/polyline.vert',
  meson.project_source_root() / 'src/shaders/2d/polyline.frag',
  meson.project_source_root() / 'src/shaders/2d/blur.vert',
  meson.project_source_root() / 'src/shaders/2d/blur.frag',
  meson.project_source_root() / 'src/shaders/2d/compute/integration.comp',
  meson.project_source_root() / 'src/shaders/2d/compute/collision_detect.comp',
  meson.project_source_root() / 'src/shaders/2d/compute/collision_resolve.comp',
]

foreach source : shader_sources
  shader_name = fs.name(source)
  custom_target(
    shader_name,
    input: files(source),
    output: shader_name + '.bin',
    command: [glslc, '-mfmt=bin', '-o', '@OUTPUT@', '@INPUT@'],
    build_by_default: true,
  )
endforeach
