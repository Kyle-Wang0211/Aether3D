// High-level pipeline selector + factory. Mirrors the intent of
// Core/Pipeline/PipelineRunner.swift without porting its full state
// machine (that file coordinates OCR / depth / training stages which
// are out-of-scope for the broker-only client today).
//
// Call site:  final client = pipelineClient();
//
// Returns a configured RemoteB1Client based on current env. If broker
// config is missing, falls back to NotConfiguredRemoteB1Client so the
// UI can still render and surface a "去设置" prompt.

import 'background_upload_broker_client.dart';
import 'broker_config.dart';
import 'not_configured_client.dart';
import 'pipeline_backend.dart';
import 'remote_b1_client.dart';

RemoteB1Client pipelineClient() {
  final backend = pipelineBackendProductDefault();
  switch (backend) {
    case PipelineBackend.brokeredBackgroundUpload:
      final cfg = BackgroundUploadBrokerConfiguration.current();
      if (cfg != null) {
        return BackgroundUploadBrokerClient(config: cfg);
      }
      return const NotConfiguredRemoteB1Client();
    case PipelineBackend.danishGoldenSSH:
    case PipelineBackend.localEmbedded:
    case PipelineBackend.notConfigured:
      return const NotConfiguredRemoteB1Client();
  }
}
