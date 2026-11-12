function createEventMock() {
  return { addListener: jest.fn() };
}

function createPortMock() {
  return {
    postMessage: jest.fn(),
    onMessage: createEventMock(),
    onDisconnect: createEventMock(),
  };
}

// Global chrome extension API mock applied before every test file
global.createChromeMock = () => ({
  runtime: {
    sendMessage: jest.fn(),
    onMessage: createEventMock(),
    connectNative: jest.fn(() => createPortMock()),
    lastError: undefined,
  },
  tabs: {
    query: jest.fn((_queryInfo, callback) => {
      const tabs = [];
      if (callback) callback(tabs);
      return Promise.resolve(tabs);
    }),
    sendMessage: jest.fn(() => Promise.resolve(undefined)),
    onRemoved: createEventMock(),
    onUpdated: createEventMock(),
  },
  scripting: {
    executeScript: jest.fn(() => Promise.resolve([])),
  },
});

global.chrome = global.createChromeMock();

beforeEach(() => {
  jest.spyOn(console, "debug").mockImplementation(() => {});
});
