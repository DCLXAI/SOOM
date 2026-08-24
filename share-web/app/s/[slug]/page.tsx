import type { Metadata } from "next";
import { ShareExperience } from "./ShareExperience";

export const metadata: Metadata = {
  title: "SOOM 공유 녹화",
  description: "화면 설명, 한국어 자막, AI TaskSpec을 한 타임라인에서 확인하세요.",
};

export default async function SharePage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  return <ShareExperience slug={slug} />;
}
