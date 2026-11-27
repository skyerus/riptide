from enum import StrEnum
from pathlib import Path
from types import SimpleNamespace as Object
import unittest
from unittest.mock import AsyncMock, Mock

from hermes_gateway_talk import Call
from hermes_ssh_talk import TalkError


class Role(StrEnum):
    USER = 'user'
    ASSISTANT = 'assistant'


class HermesGatewayTalkTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.gateway = Mock()
        self.transport = Mock()
        self.transport.events.RealtimeSessionError = RuntimeError
        self.transport.events.TranscriptRole = Role
        self.call = Call(Path('/profile'), Path('/workspace'), Path('/auth'), self.gateway, self.transport)

    async def test_refuses_an_unknown_chat_before_calling_the_provider(self):
        self.call.subscription = Mock()
        self.gateway.target.return_value = None
        with self.assertRaisesRegex(TalkError, '^wrongChat$'):
            await self.call.start('some-other-chat', 'v=0 offer')
        self.gateway.connect_gateway.assert_not_called()
        self.transport.negotiate.assert_not_called()

    async def test_never_connects_to_a_stopped_or_draining_gateway(self):
        self.gateway.discover_gateway_endpoint.return_value = Object(state='draining', endpoint=None)
        with self.assertRaisesRegex(TalkError, '^unavailable$'):
            await self.call.gateway_client()
        self.gateway.connect_gateway.assert_not_called()

    async def test_delegation_uses_the_exact_chat_and_returns_the_durable_result(self):
        self.call.target = 'paired-chat'
        self.call.transcript(Object(role=Role.USER, text='What did', start_ms=4, end_ms=500, final=False))
        self.call.transcript(Object(role=Role.ASSISTANT, text='Mm-hmm.', final=False))
        self.call.transcript(Object(role=Role.USER, text=' we decide?', start_ms=550, end_ms=900, final=False))
        self.call.session = Object(session_id='audio-id')
        self.call.speak = AsyncMock()
        self.call.client = Object(rpc=AsyncMock(side_effect=[
            {'ref': {'session_id': 'paired-chat'}, 'admission_id': 'work-id'},
            {'ref': {'session_id': 'paired-chat'}, 'admission_id': 'work-id', 'status': 'terminal',
             'result': {'final_response': 'We chose Friday.'}},
        ]))
        await self.call.delegate(Object(delegation_id='delegation-id', prompt=None, offset_ms=1000))
        submit, receipt = self.call.client.rpc.await_args_list
        self.assertEqual(submit.args, ('prompt.submit',))
        self.assertEqual(submit.kwargs['session_id'], 'paired-chat')
        self.assertEqual(submit.kwargs['text'], 'What did we decide?')
        self.assertTrue(submit.kwargs['queued'])
        self.assertTrue(submit.kwargs['input_id'].startswith('riptide-voice-'))
        self.assertEqual(receipt.args, ('prompt.receipt',))
        self.assertEqual(receipt.kwargs['admission_id'], 'work-id')
        self.call.speak.assert_awaited_once_with('delegation-id', 'We chose Friday.')
        self.assertEqual(self.call.events(0)['events'], [
            {'type': 'operation', 'sequence': 1, 'pending': True},
            {'type': 'operation', 'sequence': 2, 'pending': False},
            {'type': 'result', 'sequence': 3},
        ])
        self.call.transcript(Object(role=Role.USER, text='What did we decide?', start_ms=4, end_ms=900, final=True))
        self.assertEqual(self.call.user_delta, '')

    async def test_accepts_the_transcript_on_a_frameless_delegation(self):
        self.call.target = 'paired-chat'
        self.call.user_delta = 'The last fragment'
        self.call.session = Object(session_id='audio-id')
        self.call.speak = AsyncMock()
        self.call.result = AsyncMock(return_value='We chose Friday.')
        self.call.client = Object(rpc=AsyncMock(return_value={
            'ref': {'session_id': 'paired-chat'}, 'admission_id': 'work-id',
        }))
        await self.call.delegate(Object(delegation_id='delegation-id', prompt='What day did we choose?', offset_ms=None))
        self.assertEqual(self.call.client.rpc.await_args.kwargs['text'], 'What day did we choose?')

    async def test_refuses_to_speak_any_result_from_another_chat(self):
        self.call.target = 'paired-chat'
        self.call.client = Object(rpc=AsyncMock(return_value={
            'ref': {'session_id': 'another-chat'}, 'admission_id': 'work-id', 'status': 'terminal',
            'result': {'final_response': 'Private text'},
        }))
        with self.assertRaisesRegex(TalkError, '^invalidReply$'):
            await self.call.result('work-id')
