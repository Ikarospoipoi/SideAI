#!/usr/bin/env ruby
require 'xcodeproj'
unless defined?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  module Xcodeproj::Project::Object
    class XCLocalSwiftPackageReference < XCRemoteSwiftPackageReference
      attribute :relative_path, String
    end
  end
end
Dir.chdir(__dir__)
project = Xcodeproj::Project.new('SideAI.xcodeproj')
app = project.new_target(:application, 'SideAIPhone', :ios, '17.0')
app_group = project.main_group.new_group('SideAI', 'SideAI')
Dir['SideAI/*.swift'].sort.each { |file| app.source_build_phase.add_file_reference(app_group.new_file(File.basename(file))) }
app_group.new_file('Info.plist')
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '..'
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package; product.product_name = 'SideAIRemote'
app.package_product_dependencies << product
buildfile = project.new(Xcodeproj::Project::Object::PBXBuildFile)
buildfile.product_ref = product; app.frameworks_build_phase.files << buildfile
app.build_configurations.each do |c|
  c.build_settings.merge!({'SWIFT_VERSION'=>'5.0','PRODUCT_BUNDLE_IDENTIFIER'=>'com.ikarospoipoi.SideAI.Remote','INFOPLIST_FILE'=>'SideAI/Info.plist','TARGETED_DEVICE_FAMILY'=>'1,2','CODE_SIGN_STYLE'=>'Automatic','CURRENT_PROJECT_VERSION'=>'1','MARKETING_VERSION'=>'0.11.0','SWIFT_EMIT_LOC_STRINGS'=>'YES'})
end
tests = project.new_target(:ui_test_bundle, 'SideAIUITests', :ios, '17.0')
tests.add_dependency(app)
group = project.main_group.new_group('SideAIUITests', 'SideAIUITests')
Dir['SideAIUITests/*.swift'].sort.each { |f| tests.source_build_phase.add_file_reference(group.new_file(File.basename(f))) }
tests.build_configurations.each { |c| c.build_settings.merge!({'SWIFT_VERSION'=>'5.0','PRODUCT_BUNDLE_IDENTIFIER'=>'com.ikarospoipoi.SideAI.Remote.UITests','GENERATE_INFOPLIST_FILE'=>'YES','TEST_TARGET_NAME'=>'SideAIPhone','CODE_SIGN_STYLE'=>'Automatic'}) }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app); scheme.add_test_target(tests); scheme.set_launch_target(app)
scheme.save_as(project.path, 'SideAI', true)
