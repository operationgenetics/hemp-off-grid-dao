// Browser entry bundled by esbuild and served from this machine, never a CDN.
// Exposes only what the deploy page needs.
import { EthereumProvider } from '@walletconnect/ethereum-provider';
import QRCode from 'qrcode';
window.WC = { EthereumProvider, QRCode };
