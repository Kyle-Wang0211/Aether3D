Pod::Spec.new do |s|
  s.name             = 'aether3d_ffi'
  s.version          = '0.1.0-phase3'
  s.summary          = 'aether_cpp C ABI surface, vendored as xcframework for dart:ffi consumption.'
  s.description      = <<-DESC
    Phase 3 minimal FFI surface — currently exposes only aether_version_string()
    from aether_cpp/include/aether/aether_version.h. Built to xcframework via
    scripts/build_ios_xcframework.sh.
  DESC
  s.homepage         = 'https://github.com/Kyle-Wang0211/Aether3D'
  s.license          = { :type => 'Proprietary', :text => 'See aether_cpp/LICENSE' }
  s.author           = { 'Kyle Wang' => 'wkd20040211@gmail.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '14.0'

  # xcframework lives in dist/ at repo root (gitignored, built by
  # scripts/build_ios_xcframework.sh). Path is relative to this podspec's
  # directory (aether_cpp/), so '../dist/...' resolves to repo-root/dist/.
  s.vendored_frameworks = '../dist/aether3d_ffi.xcframework'
end
