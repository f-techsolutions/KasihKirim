import { useEffect, useState } from 'react';
import NetInfo from '@react-native-community/netinfo';
import { flush, pendingCount } from '../sync/outbox';

export function useNetwork() {
  const [online, setOnline] = useState(true);
  const [pending, setPending] = useState(0);

  useEffect(() => {
    const tick = () => setPending(pendingCount());
    tick();
    const unsub = NetInfo.addEventListener((s) => {
      const up = !!s.isConnected && s.isInternetReachable !== false;
      setOnline(up);
      if (up) void flush().then(tick);
    });
    const id = setInterval(tick, 3000);
    return () => { unsub(); clearInterval(id); };
  }, []);

  return { online, pending };
}
