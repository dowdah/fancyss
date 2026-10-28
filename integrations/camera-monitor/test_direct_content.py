from dataclasses import replace
from pathlib import Path
import unittest
from unittest import mock
import requests
from camera_monitor.config import load_config
from camera_monitor.graph import GraphClient, GraphError, require_direct_content_url
from tests.test_direct_emergency_upload import uploader_for
import tempfile

DIRECT='https://my.microsoftpersonalcontent.com/synthetic'
class DirectContentTests(unittest.TestCase):
    def client(self):
        cfg=load_config(Path(__file__).resolve().parents[1]/'deploy/config.toml.example')
        return GraphClient(cfg,sleep=lambda _:None,request_retries=0)
    def test_only_control_sessions_bind_ipv4(self):
        g=self.client()
        for session in [g.session,g.msal_http_client.session]:
            adapter=session.get_adapter('https://graph.microsoft.com')
            self.assertEqual(adapter.poolmanager.connection_pool_kw['source_address'],('0.0.0.0',0))
        self.assertNotIn('source_address',g.data_session.get_adapter(DIRECT).poolmanager.connection_pool_kw)

    def test_unknown_and_deceptive_hosts_send_no_body(self):
        g=self.client();g.data_session=mock.Mock();g.session=mock.Mock()
        for url in ['https://example.com/signed','https://files.1drv.com.evil.invalid/x','https://files.1drv.com@evil.invalid/x','http://files.1drv.com/x','https://files.1drv.com:444/x']:
            with self.subTest(url=url),self.assertRaises(GraphError):g.upload_chunk(url,b'recording',0,9)
        g.data_session.request.assert_not_called();g.session.request.assert_not_called()
    def test_body_redirect_refused_and_never_retried_via_control(self):
        g=self.client();g.session=mock.Mock();g.data_session=mock.Mock()
        response=mock.Mock(status_code=307,headers={'Location':'https://example.com/private'})
        g.data_session.request.return_value=response
        with self.assertRaises(GraphError):g.upload_chunk(DIRECT,b'x',0,1)
        self.assertEqual(g.data_session.request.call_count,1)
        self.assertFalse(g.data_session.request.call_args.kwargs['allow_redirects'])
        g.session.request.assert_not_called();response.close.assert_called_once()
    def test_connection_failure_has_no_proxy_fallback(self):
        g=self.client();self.assertFalse(g.data_session.trust_env)
        g.session=mock.Mock();g.data_session.request=mock.Mock(side_effect=requests.ConnectionError())
        with self.assertRaises(GraphError):g.upload_chunk(DIRECT,b'x',0,1)
        g.session.request.assert_not_called()
    def test_range_separates_graph_redirect_from_body_request(self):
        g=self.client();g.download_url=mock.Mock(return_value=DIRECT);g.data_session=mock.Mock()
        g.data_session.request.return_value=mock.Mock(status_code=206,headers={'Content-Range':'bytes 10-12/20'})
        g.data_session.request.return_value.iter_content.return_value=iter([b'abc'])
        self.assertEqual(g.download_range('id',10,3),b'abc')
        call=g.data_session.request.call_args
        self.assertEqual(call.args,('GET',DIRECT));self.assertEqual(call.kwargs['headers'],{'Range':'bytes=10-12'})
        self.assertFalse(call.kwargs['allow_redirects'])
    def test_viewing_small_recording_uses_validated_upload_session(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'clip.mp4';path.write_bytes(b'clip')
            u,g=uploader_for(path);u.kind_filter='viewing'
            g.create_upload_session.return_value={'uploadUrl':DIRECT}
            g.upload_chunk.return_value=mock.Mock(status_code=201)
            g.upload_chunk.return_value.json.return_value={'id':'r','size':4}
            u.upload_one({'id':1,'kind':'viewing','state':'QUEUED','relative_path':'clip.mp4','local_path':str(path),'size_bytes':4})
            g.upload_small.assert_not_called();g.upload_chunk.assert_called_once()
    def test_download_redirect_is_validated_before_body(self):
        g=self.client();g.request=mock.Mock(return_value=mock.Mock(headers={'Location':'https://example.com/signed'}));g.data_session=mock.Mock()
        with self.assertRaises(GraphError):g.download_url('id')
        g.data_session.request.assert_not_called()

    def test_range_ignoring_server_is_rejected_before_body_read(self):
        g=self.client();g.download_url=mock.Mock(return_value=DIRECT);g.data_session=mock.Mock()
        response=mock.Mock(status_code=200)
        g.data_session.request.return_value=response
        with self.assertRaises(GraphError):g.download_range('id',0,3)
        response.iter_content.assert_not_called();response.close.assert_called_once()
