Pod::Spec.new do |s|
  s.name             = 'vpn_bridge'
  s.version          = '1.0.0'
  s.summary          = 'FlClash iOS VPN 桥'
  s.description      = 'VPN 控制 + App Group 消息通道'
  s.homepage         = 'https://github.com/laona/FlClash'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'laona' => 'laona@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'vpn_bridge/Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.swift_version = '5.0'
  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
