import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: { default: "SOOM", template: "%s · SOOM" },
  description: "화면·얼굴·음성 설명을 영상과 실행 가능한 AI TaskSpec으로 공유하세요.",
  icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
  openGraph: {
    title: "SOOM — Show it. Say it. Ship it.",
    description: "영상과 AI 작업이 한 타임라인에서 만나는 개발 피드백 공유 경험",
    type: "website",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "SOOM video to AI TaskSpec" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "SOOM — Show it. Say it. Ship it.",
    description: "영상과 AI 작업이 한 타임라인에서 만나는 개발 피드백 공유 경험",
    images: ["/og.png"],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="ko"><body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body></html>;
}
