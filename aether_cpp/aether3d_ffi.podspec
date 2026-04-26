Pod::Spec.new do |s|
  s.name             = 'aether3d_ffi'
  s.version          = '0.1.0-phase3'
  s.summary          = 'aether_cpp C ABI surface, vendored as per-arch .a for dart:ffi consumption.'
  s.description      = <<-DESC
    Phase 3 minimal FFI surface — currently exposes only aether_version_string()
    from aether_cpp/include/aether/aether_version.h. Built to per-arch static
    libraries via scripts/build_ios_xcframework.sh (which also keeps an
    xcframework around for non-CocoaPods consumers).

    Phase 5.0 (D2) layout: dist/libs/{ios-arm64,ios-arm64-simulator}/libaether3d_ffi.a.
    The xcframework wrapper is skipped for the Pod consumer because CocoaPods 1.16
    + use_frameworks! + vendored_frameworks of a static xcframework hit a known
    bug where the slice .a never gets extracted into the link phase.
  DESC
  s.homepage         = 'https://github.com/Kyle-Wang0211/Aether3D'
  s.license          = { :type => 'Proprietary', :text => 'See aether_cpp/LICENSE' }
  s.author           = { 'Kyle Wang' => 'wkd20040211@gmail.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '14.0'

  # Public C header — copied into Pods/Headers/Public/aether3d_ffi/.
  # Path resolves relative to this podspec (aether_cpp/aether3d_ffi.podspec),
  # so 'include/aether/aether_version.h' = 'aether_cpp/include/aether/aether_version.h'.
  s.source_files        = 'include/aether/aether_version.h'
  s.public_header_files = 'include/aether/aether_version.h'

  # Per-arch .a files live at <repo>/dist/libs/{ios-arm64,ios-arm64-simulator}/.
  # Path is relative to podspec dir → '../dist/libs/...'. preserve_paths keeps
  # them around in Pods/aether3d_ffi/ so the linker can find them via
  # LIBRARY_SEARCH_PATHS below.
  s.preserve_paths      = '../dist/libs/**/*'

  # Phase 5.0 D2 — vendored per-arch .a, conditionally linked by SDK.
  #
  # NOTE on why we use LIBRARY_SEARCH_PATHS[sdk=…] instead of
  # `s.vendored_libraries = '../dist/libs/**/libaether3d_ffi.a'` glob:
  # Both slices are non-fat arm64 binaries (Apple Silicon simulator dropped
  # x86_64), differing only by Mach-O platform marker. A glob feeds BOTH .a
  # files to the linker for every build, which fails with "object file built
  # for iOS Simulator, but linking for iOS" (or vice versa). VALID_ARCHS
  # doesn't filter input archives — only target output archs. The idiomatic
  # CocoaPods pattern is per-sdk LIBRARY_SEARCH_PATHS + a single -laether3d_ffi
  # in OTHER_LDFLAGS, so each SDK build only sees its own slice.
  s.pod_target_xcconfig = {
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]'        => '$(PODS_TARGET_SRCROOT)/../dist/libs/ios-arm64',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => '$(PODS_TARGET_SRCROOT)/../dist/libs/ios-arm64-simulator',
    'OTHER_LDFLAGS'                              => '-laether3d_ffi',
    # Keep arch matrix tight — both slices are arm64-only on purpose.
    'VALID_ARCHS[sdk=iphoneos*]'                 => 'arm64',
    'VALID_ARCHS[sdk=iphonesimulator*]'          => 'arm64',
  }

  # User target (Runner.app) link line.
  #
  # -force_load is REQUIRED for FFI consumption: dart:ffi looks up symbols
  # via dlsym(RTLD_DEFAULT, …) at runtime. Without -force_load, the static
  # linker has no Swift/ObjC reference to aether_version_string and dead-
  # strips the entire .a from the binary → dlsym returns NULL at runtime.
  # -laether3d_ffi alone only links symbols statically referenced from
  # other input objects; -force_load drags in the whole archive.
  #
  # Path is sdk-conditional because the device and simulator slices are
  # both arm64 but mark different platforms; linker rejects cross-platform.
  # PODS_ROOT resolves to <ios>/Pods at build time, so '../../../dist' goes
  # up to repo root then into dist/.
  s.user_target_xcconfig = {
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]'        => '$(PODS_ROOT)/../../../dist/libs/ios-arm64',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => '$(PODS_ROOT)/../../../dist/libs/ios-arm64-simulator',
    # NB: $(inherited) preserves CocoaPods's own -ObjC + Pod link flags.
    # Without it, OTHER_LDFLAGS[sdk=…] would override the base entirely.
    'OTHER_LDFLAGS[sdk=iphoneos*]'               => '$(inherited) -force_load $(PODS_ROOT)/../../../dist/libs/ios-arm64/libaether3d_ffi.a',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]'        => '$(inherited) -force_load $(PODS_ROOT)/../../../dist/libs/ios-arm64-simulator/libaether3d_ffi.a',
  }
end
