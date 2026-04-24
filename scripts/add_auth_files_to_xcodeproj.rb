#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off script: register the firebase-auth feature's new App/Auth/*.swift
# sources and the GoogleService-Info.plist resource with the existing
# Aether3DApp.xcodeproj. Core/Auth/*.swift files are already picked up
# automatically via the Aether3DCore SPM target (path: "Core").
#
# Safe to re-run: looks up files by path and skips duplicates.

require "xcodeproj"
require "pathname"

PROJECT_ROOT = Pathname.new(__dir__).parent.expand_path
PROJECT_PATH = PROJECT_ROOT.join("Aether3DApp.xcodeproj")
TARGET_NAME  = "Aether3DApp"

AUTH_SWIFT_FILES = %w[
  App/Auth/AuthRootView.swift
  App/Auth/AuthSharedViews.swift
  App/Auth/EmailSignInView.swift
  App/Auth/PhoneSignInView.swift
].freeze

PLIST_PATH = "GoogleService-Info.plist".freeze

project = Xcodeproj::Project.open(PROJECT_PATH.to_s)
target = project.targets.find { |t| t.name == TARGET_NAME } or
  abort "target #{TARGET_NAME} not found"

app_group = project.main_group["App"] || project.main_group.new_group("App", "App")
auth_group = app_group["Auth"] || app_group.new_group("Auth", "Auth")

# Register Swift sources --------------------------------------------------
AUTH_SWIFT_FILES.each do |rel_path|
  basename = File.basename(rel_path)
  already_ref = auth_group.files.find { |f| f.path == basename }
  file_ref = already_ref || auth_group.new_reference(basename)

  if target.source_build_phase.files.any? { |bf| bf.file_ref == file_ref }
    puts "= source already linked: #{rel_path}"
  else
    target.source_build_phase.add_file_reference(file_ref)
    puts "+ source added:        #{rel_path}"
  end
end

# Register the GoogleService-Info.plist as a resource at the project root.
root_group = project.main_group
existing_plist = root_group.files.find { |f| f.path == PLIST_PATH }
plist_ref = existing_plist || root_group.new_reference(PLIST_PATH)
# Ensure SOURCE_ROOT so Xcode doesn't try to relativize it weirdly.
plist_ref.source_tree = "SOURCE_ROOT"

if target.resources_build_phase.files.any? { |bf| bf.file_ref == plist_ref }
  puts "= resource already linked: #{PLIST_PATH}"
else
  target.resources_build_phase.add_file_reference(plist_ref)
  puts "+ resource added:        #{PLIST_PATH}"
end

project.save
puts "saved #{PROJECT_PATH}"
