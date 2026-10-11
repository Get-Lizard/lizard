// Lizard's implementation of the public `@raycast/utils` helpers: data hooks, forms,
// AppleScript, favicons and friends.
"use strict";

const React = require("react");
const { execFile } = require("node:child_process");
const api = require("./api");

const { useState, useEffect, useRef, useCallback, useMemo } = React;

// ---------------------------------------------------------------------------------------------
// usePromise: runs an async function with arguments; re-runs when the arguments change.

function usePromise(fn, args = [], options = {}) {
  const { execute = true, initialData, onData, onError, onWillExecute, failureToastOptions } = options;
  const [state, setState] = useState({ data: initialData, isLoading: execute, error: undefined });
  const latest = useRef({ fn, args, options });
  latest.current = { fn, args, options };
  const callId = useRef(0);
  const abortable = options.abortable;

  const run = useCallback(async (...runArgs) => {
    const id = ++callId.current;
    const callArgs = runArgs.length ? runArgs : latest.current.args;
    if (abortable) {
      abortable.current?.abort();
      abortable.current = new AbortController();
    }
    latest.current.options.onWillExecute?.(callArgs);
    setState((previous) => ({ ...previous, isLoading: true }));
    try {
      let data = await latest.current.fn(...callArgs);
      // Paginated functions return a function of the page options.
      if (typeof data === "function") {
        const page = await data({ page: 0, cursor: undefined, lastItem: undefined });
        data = page?.data ?? page;
      }
      if (id === callId.current) {
        setState({ data, isLoading: false, error: undefined });
        latest.current.options.onData?.(data);
      }
      return data;
    } catch (error) {
      if (id === callId.current) {
        setState((previous) => ({ ...previous, isLoading: false, error }));
        if (latest.current.options.onError) latest.current.options.onError(error);
        else if (error?.name !== "AbortError") showFailureToast(error, failureToastOptions);
      }
      throw error;
    }
  }, []);

  const key = JSON.stringify(args ?? []);
  useEffect(() => {
    if (execute) run().catch(() => {});
    else setState((previous) => ({ ...previous, isLoading: false }));
  }, [key, execute]);

  const mutate = useCallback(async (asyncUpdate, mutateOptions = {}) => {
    let previous;
    if (mutateOptions.optimisticUpdate) {
      setState((current) => {
        previous = current.data;
        return { ...current, data: mutateOptions.optimisticUpdate(current.data) };
      });
    }
    try {
      const result = await asyncUpdate;
      if (mutateOptions.shouldRevalidateAfter !== false) await run().catch(() => {});
      return result;
    } catch (error) {
      if (mutateOptions.rollbackOnError !== false && mutateOptions.optimisticUpdate) {
        setState((current) => ({ ...current, data: typeof mutateOptions.rollbackOnError === "function" ? mutateOptions.rollbackOnError(current.data) : previous }));
      }
      throw error;
    }
  }, [run]);

  return {
    data: state.data, isLoading: state.isLoading, error: state.error,
    revalidate: () => run().catch(() => {}), mutate, pagination: undefined,
  };
}

// ---------------------------------------------------------------------------------------------
// Cached variants: last result is kept in the Cache so the next launch shows it instantly.

const sharedCache = new api.Cache({ namespace: "lizard-utils" });

function useCachedState(key, initialState, config = {}) {
  const cache = useMemo(() => (config.cacheNamespace ? new api.Cache({ namespace: config.cacheNamespace }) : sharedCache), [config.cacheNamespace]);
  const [value, setValue] = useState(() => {
    const stored = cache.get(`state:${key}`);
    return stored === undefined ? initialState : stored;
  });
  const update = useCallback((next) => {
    setValue((current) => {
      const resolved = typeof next === "function" ? next(current) : next;
      cache.set(`state:${key}`, resolved);
      return resolved;
    });
  }, [key, cache]);
  return [value, update];
}

function useCachedPromise(fn, args = [], options = {}) {
  const cacheKey = `promise:${options.keepPreviousData ? "" : ""}${hash(String(fn) + JSON.stringify(args ?? []))}`;
  const cached = sharedCache.get(cacheKey);
  const result = usePromise(fn, args, {
    ...options,
    initialData: cached === undefined ? options.initialData : cached,
    onData: (data) => {
      try {
        sharedCache.set(cacheKey, data);
      } catch {}
      options.onData?.(data);
    },
  });
  if (result.data === undefined && cached !== undefined) return { ...result, data: cached };
  return result;
}

function hash(text) {
  let value = 5381;
  for (let index = 0; index < text.length; index++) value = (value * 33) ^ text.charCodeAt(index);
  return (value >>> 0).toString(36);
}

// ---------------------------------------------------------------------------------------------
// Fetch, exec, storage

function useFetch(url, options = {}) {
  const { parseResponse, mapResult, execute, initialData, keepPreviousData, onData, onError, onWillExecute, failureToastOptions, ...init } = options;
  return useCachedPromise(
    async (target) => {
      const response = await fetch(target, init);
      if (!response.ok && !parseResponse) throw new Error(`${response.status} ${response.statusText}`);
      const parsed = parseResponse ? await parseResponse(response) : await defaultParse(response);
      return mapResult ? mapResult(parsed).data : parsed;
    },
    [typeof url === "function" ? url({ page: 0 }) : url],
    { execute, initialData, keepPreviousData, onData, onError, onWillExecute, failureToastOptions },
  );
}

async function defaultParse(response) {
  const type = response.headers.get("content-type") ?? "";
  return type.includes("json") ? response.json() : response.text();
}

function useExec(command, argsOrOptions, maybeOptions) {
  const args = Array.isArray(argsOrOptions) ? argsOrOptions : [];
  const options = (Array.isArray(argsOrOptions) ? maybeOptions : argsOrOptions) ?? {};
  return usePromise(
    (cmd, cmdArgs) =>
      new Promise((resolve, reject) => {
        const shell = options.shell ? (typeof options.shell === "string" ? options.shell : "/bin/zsh") : null;
        const file = shell ?? cmd;
        const fileArgs = shell ? ["-lc", [cmd, ...cmdArgs].join(" ")] : cmdArgs;
        const child = execFile(file, fileArgs, { cwd: options.cwd, env: { ...process.env, ...(options.env ?? {}) }, maxBuffer: 64 * 1024 * 1024, timeout: options.timeout }, (error, stdout, stderr) => {
          if (error) return reject(Object.assign(error, { stderr }));
          const output = options.stripFinalNewline === false ? stdout : stdout.replace(/\n$/, "");
          resolve(options.parseOutput ? options.parseOutput({ stdout: output, stderr, exitCode: 0 }) : output);
        });
        if (options.input != null) child.stdin.end(options.input);
      }),
    [command, args],
    options,
  );
}

function useLocalStorage(key, initialValue) {
  const result = usePromise(async (storageKey) => {
    const stored = await api.LocalStorage.getItem(storageKey);
    return stored === undefined ? initialValue : JSON.parse(stored);
  }, [key]);
  return {
    value: result.data,
    isLoading: result.isLoading,
    setValue: async (value) => {
      await api.LocalStorage.setItem(key, JSON.stringify(value));
      result.revalidate();
    },
    removeValue: async () => {
      await api.LocalStorage.removeItem(key);
      result.revalidate();
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Forms

const FormValidation = Object.freeze({ Required: "required" });

function useForm({ onSubmit, validation = {}, initialValues = {} }) {
  const [values, setValues] = useState(initialValues);
  const [errors, setErrors] = useState({});
  const valuesRef = useRef(values);
  valuesRef.current = values;

  const validate = (id, value) => {
    const rule = validation[id];
    if (!rule) return undefined;
    if (rule === FormValidation.Required) {
      const empty = value == null || value === "" || (Array.isArray(value) && value.length === 0);
      return empty ? "The item is required" : undefined;
    }
    return typeof rule === "function" ? rule(value) : undefined;
  };

  const itemProps = new Proxy({}, {
    get: (_, id) => ({
      id,
      value: valuesRef.current[id],
      error: errors[id],
      onChange: (value) => {
        setValues((current) => ({ ...current, [id]: value }));
        if (errors[id]) setErrors((current) => ({ ...current, [id]: validate(id, value) }));
      },
      onBlur: () => setErrors((current) => ({ ...current, [id]: validate(id, valuesRef.current[id]) })),
    }),
  });

  const handleSubmit = async (submitted) => {
    const merged = { ...valuesRef.current, ...submitted };
    const found = {};
    for (const id of Object.keys(validation)) {
      const message = validate(id, merged[id]);
      if (message) found[id] = message;
    }
    setErrors(found);
    if (Object.keys(found).length) return false;
    return onSubmit(merged);
  };

  return {
    handleSubmit, itemProps, values,
    setValue: (id, value) => setValues((current) => ({ ...current, [id]: value })),
    setValidationError: (id, message) => setErrors((current) => ({ ...current, [id]: message })),
    reset: (next) => setValues(next ?? initialValues),
    focus: () => {},
  };
}

// ---------------------------------------------------------------------------------------------
// Misc helpers

async function showFailureToast(error, options = {}) {
  const message = error instanceof Error ? error.message : String(error);
  return api.showToast({ style: api.Toast.Style.Failure, title: options.title ?? "Something went wrong", message, primaryAction: options.primaryAction });
}

function runAppleScript(script, argsOrOptions, maybeOptions) {
  const args = Array.isArray(argsOrOptions) ? argsOrOptions : [];
  const options = (Array.isArray(argsOrOptions) ? maybeOptions : argsOrOptions) ?? {};
  const language = options.language === "JavaScript" ? ["-l", "JavaScript"] : [];
  return new Promise((resolve, reject) => {
    execFile("/usr/bin/osascript", [...language, "-e", script, ...args], { timeout: options.timeout ?? 10000 }, (error, stdout, stderr) => {
      if (error) return reject(new Error(stderr?.trim() || error.message));
      const output = stdout.replace(/\n$/, "");
      resolve(options.parseOutput ? options.parseOutput({ stdout: output, stderr, exitCode: 0 }) : output);
    });
  });
}

function getFavicon(url, options = {}) {
  try {
    const domain = new URL(typeof url === "string" ? url : url.href).hostname;
    return { source: `https://icons.duckduckgo.com/ip3/${domain}.ico`, fallback: options.fallback ?? api.Icon.Globe, mask: options.mask };
  } catch {
    return options.fallback ?? api.Icon.Globe;
  }
}

function getAvatarIcon(name) {
  const initials = String(name ?? "?").split(/\s+/).map((part) => part[0]).join("").slice(0, 2).toUpperCase();
  return `initials:${initials}`;
}

function getProgressIcon(progress) {
  return `progress:${Math.max(0, Math.min(1, Number(progress) || 0))}`;
}

function withCache(fn, options = {}) {
  const cache = new api.Cache({ namespace: "with-cache" });
  return async (...args) => {
    const key = hash(String(fn) + JSON.stringify(args));
    const stored = cache.get(key);
    if (stored && (!options.maxAge || Date.now() - stored.time < options.maxAge)) return stored.value;
    const value = await fn(...args);
    if (!options.validate || options.validate(value)) cache.set(key, { value, time: Date.now() });
    return value;
  };
}

function useFrecencySorting(data, options = {}) {
  const [visits, setVisits] = useCachedState(`frecency:${options.namespace ?? "default"}`, {});
  const keyOf = options.key ?? ((item) => item.id);
  const sorted = useMemo(() => {
    if (!data) return [];
    const now = Date.now();
    const score = (item) => {
      const record = visits[keyOf(item)];
      if (!record) return 0;
      return record.count * Math.pow(0.5, (now - record.last) / (7 * 24 * 3600 * 1000));
    };
    return [...data].sort((a, b) => score(b) - score(a) || (options.sortUnvisited ? options.sortUnvisited(a, b) : 0));
  }, [data, visits]);
  return {
    data: sorted,
    visitItem: async (item) => setVisits((current) => ({ ...current, [keyOf(item)]: { count: (current[keyOf(item)]?.count ?? 0) + 1, last: Date.now() } })),
    resetRanking: async (item) => setVisits((current) => {
      const next = { ...current };
      delete next[keyOf(item)];
      return next;
    }),
  };
}

/** Streams by default (`stream: false` waits for the whole answer), like Raycast's useAI. */
function useAI(prompt, options = {}) {
  const execute = options.execute ?? true;
  const [data, setData] = useState("");
  const [isLoading, setLoading] = useState(execute);
  const [error, setError] = useState();
  const [nonce, setNonce] = useState(0);
  const optionsRef = useRef(options);
  optionsRef.current = options;

  useEffect(() => {
    if (!execute) return undefined;
    let cancelled = false;
    setData("");
    setError(undefined);
    setLoading(true);
    const request = api.AI.ask(prompt, { model: optionsRef.current.model, creativity: optionsRef.current.creativity });
    if (optionsRef.current.stream !== false) request.on("data", (chunk) => !cancelled && setData((text) => text + chunk));
    request.then(
      (text) => {
        if (cancelled) return;
        setData(text);
        setLoading(false);
        optionsRef.current.onData?.(text);
      },
      (reason) => {
        if (cancelled) return;
        setError(reason);
        setLoading(false);
        if (optionsRef.current.onError) optionsRef.current.onError(reason);
        else showFailureToast(reason, { title: "AI request failed" });
      },
    );
    return () => {
      cancelled = true;
    };
  }, [prompt, execute, nonce]);

  return { data, isLoading, error, revalidate: useCallback(() => setNonce((n) => n + 1), []) };
}

function createDeeplink(options) {
  return `lizard://extensions/${options.extensionName ?? api.environment.extensionName}/${options.command}`;
}

const DeeplinkType = Object.freeze({ Extension: "extension", ScriptCommand: "scriptCommand" });

module.exports = {
  usePromise, useCachedPromise, useCachedState, useFetch, useExec, useLocalStorage, useForm, FormValidation,
  showFailureToast, runAppleScript, getFavicon, getAvatarIcon, getProgressIcon, withCache, useFrecencySorting, useAI,
  createDeeplink, DeeplinkType,
};
