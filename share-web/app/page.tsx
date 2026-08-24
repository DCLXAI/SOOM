import type { Metadata } from "next";
import { ShareExperience } from "./s/[slug]/ShareExperience";

export const metadata: Metadata = {
  title: "SOOM — 화면으로 설명하고 바로 공유하세요",
  description: "화면·얼굴·음성·AI TaskSpec이 하나로 연결된 개발 피드백 공유 페이지",
};

export default function Home() {
  return <ShareExperience slug="demo" demo />;
}
