import { StrictMode } from "react"
import { createRoot } from "react-dom/client"

import "@/index.css"
import { Toaster } from "@/components/ui/sonner"
import { TooltipProvider } from "@/components/ui/tooltip"
import { Popup } from "./Popup"

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <TooltipProvider delayDuration={400}>
      <Popup />
      <Toaster position="bottom-center" />
    </TooltipProvider>
  </StrictMode>
)
