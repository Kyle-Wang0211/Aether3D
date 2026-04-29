// Dart port of Core/Pipeline/NotConfiguredRemoteB1Client.swift.
// Dummy client used when no broker endpoint is configured. Every call
// fails with a distinct "api_not_configured" error so the UI can show
// a helpful "前往设置 → 云端配置" message instead of silent failure.

import 'remote_b1_client.dart';

class NotConfiguredRemoteB1Client implements RemoteB1Client {
  const NotConfiguredRemoteB1Client();

  @override
  Future<String> upload({
    required String videoFilePath,
    void Function(RemoteUploadProgress)? onProgress,
  }) async {
    throw const RemoteB1ClientException(
      code: 'api_not_configured',
      message: '云端未配置，请在设置中填写 AETHER_BROKER_BASE_URL。',
    );
  }

  @override
  Future<String> startJob({required String assetId}) async {
    throw const RemoteB1ClientException(
      code: 'api_not_configured',
      message: '云端未配置，请在设置中填写 AETHER_BROKER_BASE_URL。',
    );
  }

  @override
  Future<JobStatus> pollStatus({required String jobId}) async {
    throw const RemoteB1ClientException(
      code: 'api_not_configured',
      message: '云端未配置，请在设置中填写 AETHER_BROKER_BASE_URL。',
    );
  }

  @override
  Future<DownloadedArtifact> download({required String jobId}) async {
    throw const RemoteB1ClientException(
      code: 'api_not_configured',
      message: '云端未配置，请在设置中填写 AETHER_BROKER_BASE_URL。',
    );
  }

  @override
  Future<void> cancel({required String jobId}) async {
    throw const RemoteB1ClientException(
      code: 'api_not_configured',
      message: '云端未配置，请在设置中填写 AETHER_BROKER_BASE_URL。',
    );
  }
}
