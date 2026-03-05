import { useCreateBlockNote } from "@blocknote/react";
import { BlockNoteView } from "@blocknote/mantine";
import {
  AIExtension,
  AIMenuController,
  getAISlashMenuItems,
} from "@blocknote/xl-ai";
import { en as aiEn } from "@blocknote/xl-ai/locales";
import { DefaultChatTransport } from "ai";
import {
  ExperimentalMobileFormattingToolbarController,
  SuggestionMenuController,
  getDefaultReactSlashMenuItems,
} from "@blocknote/react";
import { filterSuggestionItems } from "@blocknote/core/extensions";
import { en } from "@blocknote/core/locales";

import "@blocknote/core/fonts/inter.css";
import "@blocknote/mantine/style.css";
import "@blocknote/xl-ai/style.css";

import { useCallback, useEffect, useMemo, useState } from "react";
import "./types";
import "./App.css";

function App() {
  // Read initial theme from Swift-injected variable so we render with the
  // correct theme on the very first frame — no light→dark flash.
  const [theme, setThemeState] = useState<"light" | "dark">(
    () => (window as any).initialTheme === "dark" ? "dark" : "light"
  );

  // Build AI transport — reads the injected API key from window
  const aiTransport = useMemo(() => {
    const endpoint =
      window.AI_ENDPOINT || "https://api.openai.com/v1/chat/completions";
    return new DefaultChatTransport({
      api: endpoint,
      headers: (): Record<string, string> => {
        const key = window.AI_API_KEY;
        if (!key) return {} as Record<string, string>;
        return {
          Authorization: `Bearer ${key}`,
        } as Record<string, string>;
      },
    });
  }, []);

  // Create the BlockNote editor with AI extension
  const editor = useCreateBlockNote({
    dictionary: {
      ...en,
      ai: aiEn,
    },
    extensions: [
      AIExtension({
        transport: aiTransport,
      }),
    ],
  });

  // Expose editor instance for Swift bridge
  useEffect(() => {
    (window as any).blocknoteEditor = editor;
  }, [editor]);

  // Bridge: content change handler → Swift
  useEffect(() => {
    const onChange = () => {
      const blocks = editor.document;
      const blocksJSON = JSON.stringify(blocks);

      // Extract title from the first heading or paragraph block
      let title: string | undefined;
      if (blocks.length > 0) {
        const first = blocks[0];
        if (first.content && Array.isArray(first.content)) {
          title = first.content
            .map((c: any) => (typeof c === "string" ? c : c.text || ""))
            .join("");
        }
      }

      window.webkit?.messageHandlers?.editorBridge?.postMessage({
        type: "contentChange",
        blocksJSON,
        title,
      });
    };

    editor.onChange(onChange);
  }, [editor]);

  // Bridge: load document from Swift
  const loadDocument = useCallback(
    (blocks: any[]) => {
      if (blocks && blocks.length > 0) {
        editor.replaceBlocks(editor.document, blocks);
      }
    },
    [editor]
  );

  // Bridge: set theme from Swift
  const setTheme = useCallback((t: "light" | "dark") => {
    setThemeState(t);
  }, []);

  // Bridge: export to markdown/HTML from arbitrary blocks JSON
  const exportMarkdown = useCallback(
    async (blocksJSON: string): Promise<string> => {
      const blocks = JSON.parse(blocksJSON);
      return await editor.blocksToMarkdownLossy(blocks);
    },
    [editor]
  );

  const exportHTML = useCallback(
    async (blocksJSON: string): Promise<string> => {
      const blocks = JSON.parse(blocksJSON);
      return await editor.blocksToHTMLLossy(blocks);
    },
    [editor]
  );

  const exportFullHTML = useCallback(
    async (blocksJSON: string): Promise<string> => {
      const blocks = JSON.parse(blocksJSON);
      return await editor.blocksToFullHTML(blocks);
    },
    [editor]
  );

  // Bridge: insert text at the current cursor position (for voice dictation).
  const insertTextAtCursor = useCallback(
    (text: string) => {
      if (!text) return;
      const tiptap = (editor as any)._tiptapEditor;
      if (tiptap) {
        tiptap.chain().focus().insertContent(text).run();
      }
    },
    [editor]
  );

  // Bridge: check if the editor currently has focus
  const editorHasFocus = useCallback((): boolean => {
    const tiptap = (editor as any)._tiptapEditor;
    return tiptap?.isFocused ?? false;
  }, [editor]);

  // Bridge: get the currently selected text in the editor
  const getSelectedText = useCallback((): string => {
    const tiptap = (editor as any)._tiptapEditor;
    if (!tiptap) return "";
    const { from, to } = tiptap.state.selection;
    if (from === to) return "";
    return tiptap.state.doc.textBetween(from, to, " ");
  }, [editor]);

  // Bridge: parse markdown into blocks and load into editor.
  const loadMarkdown = useCallback(
    async (markdown: string) => {
      if (!markdown) return;
      const blocks = await editor.tryParseMarkdownToBlocks(markdown);
      editor.replaceBlocks(editor.document, blocks);
    },
    [editor]
  );

  // Register bridge functions on window
  useEffect(() => {
    window.loadDocument = loadDocument;
    window.setTheme = setTheme;
    window.exportMarkdown = exportMarkdown;
    window.exportHTML = exportHTML;
    window.exportFullHTML = exportFullHTML;
    window.insertTextAtCursor = insertTextAtCursor;
    window.editorHasFocus = editorHasFocus;
    window.getSelectedText = getSelectedText;
    window.loadMarkdown = loadMarkdown;

    // Notify Swift that the editor is ready
    window.webkit?.messageHandlers?.editorBridge?.postMessage({
      type: "ready",
    });

    return () => {
      delete window.loadDocument;
      delete window.setTheme;
      delete window.exportMarkdown;
      delete window.exportHTML;
      delete window.exportFullHTML;
      delete window.insertTextAtCursor;
      delete window.editorHasFocus;
      delete window.getSelectedText;
      delete window.loadMarkdown;
    };
  }, [loadDocument, setTheme, exportMarkdown, exportHTML, exportFullHTML, insertTextAtCursor, editorHasFocus, getSelectedText, loadMarkdown]);

  // Detect system dark mode when not in native wrapper
  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const handler = (e: MediaQueryListEvent) => {
      if (!window.webkit?.messageHandlers?.editorBridge) {
        setThemeState(e.matches ? "dark" : "light");
      }
    };
    mq.addEventListener("change", handler);
    if (!window.webkit?.messageHandlers?.editorBridge) {
      setThemeState(mq.matches ? "dark" : "light");
    }
    return () => mq.removeEventListener("change", handler);
  }, []);

  return (
    <div
      style={{
        height: "100vh",
        overflowY: "auto" as const,
        background: theme === "dark" ? "#1e1e1e" : "#ffffff",
        color: theme === "dark" ? "#e0e0e0" : "#1a1a1a",
      }}
    >
      <BlockNoteView
        editor={editor}
        theme={theme}
        formattingToolbar={false}
        slashMenu={false}
      >
        {/* Mobile formatting toolbar — sits above the iOS keyboard */}
        <ExperimentalMobileFormattingToolbarController />

        {/* Slash menu with AI items */}
        <SuggestionMenuController
          triggerCharacter="/"
          getItems={async (query) =>
            filterSuggestionItems(
              [
                ...getDefaultReactSlashMenuItems(editor),
                ...getAISlashMenuItems(editor),
              ],
              query
            )
          }
        />

        {/* AI menu controller (handles /ai interactions) */}
        <AIMenuController />
      </BlockNoteView>
    </div>
  );
}

export default App;
