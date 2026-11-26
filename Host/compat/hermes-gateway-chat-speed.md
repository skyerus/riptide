# Remember chat speed in Hermes

The Riptide speed button changes the selected Hermes chat. This patch saves each explicit choice in the owning profile's existing state database so Hermes can use it after the gateway restarts. A chat with no saved choice follows its existing policy. Existing chats can save a choice the next time their speed is selected.

The patch targets Hermes revision `8fc0374447313e276f6b9a2764bfc750190c966a` and works alongside the other Riptide compatibility patches. From the Hermes checkout, using the patch from a versioned Riptide release:

```sh
git apply --check /absolute/riptide/Host/compat/hermes-gateway-chat-speed.patch
git apply /absolute/riptide/Host/compat/hermes-gateway-chat-speed.patch
```

Gracefully restart the Hermes gateway after active turns finish. Reopen a chat in Riptide and choose its speed. On the next gateway restart, reopen the same chat and check that the selected speed is still shown.

To roll back, reverse the patch with `git apply -R` and restart the gateway after active turns finish.
