import unittest
from unittest.mock import AsyncMock

from hermes_mobile import emulate_tab, mobile_identity


class MobileViewTests(unittest.IsolatedAsyncioTestCase):
    async def test_handled_tab_gets_a_mobile_viewport_headers_and_touch_before_resuming(self):
        identity = mobile_identity({"product": "Chrome/156.0.8078.80"})
        cdp = AsyncMock()
        cdp.call.return_value = {
            "cssLayoutViewport": {"clientWidth": 520, "clientHeight": 680},
        }

        await emulate_tab(cdp, {"sessionId": "new-page", "waitingForDebugger": True}, identity)

        layout, metrics, touch, user_agent, resume = cdp.call.await_args_list
        self.assertEqual(layout.args[0], "Page.getLayoutMetrics")
        self.assertEqual(metrics.args[0], "Emulation.setDeviceMetricsOverride")
        self.assertEqual(metrics.args[1]["width"], 390)
        self.assertTrue(metrics.args[1]["mobile"])
        self.assertEqual(touch.args, ("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5}))
        self.assertEqual(user_agent.args[0], "Emulation.setUserAgentOverride")
        self.assertIn("Chrome/156.0.0.0 Mobile", user_agent.args[1]["userAgent"])
        self.assertTrue(user_agent.args[1]["userAgentMetadata"]["mobile"])
        self.assertEqual(user_agent.args[1]["userAgentMetadata"]["platform"], "Android")
        self.assertEqual(resume.args[0], "Runtime.runIfWaitingForDebugger")
        self.assertTrue(all(call.kwargs == {"session": "new-page"} for call in cdp.call.await_args_list))
