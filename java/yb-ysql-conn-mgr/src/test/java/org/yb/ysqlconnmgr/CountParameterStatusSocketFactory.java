// Copyright (c) YugabyteDB, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
// in compliance with the License. You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software distributed under the License
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
// or implied. See the License for the specific language governing permissions and limitations
// under the License.
//

package org.yb.ysqlconnmgr;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.util.concurrent.atomic.AtomicInteger;

import javax.net.SocketFactory;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * A SocketFactory implementation that creates sockets which inspect the inbound PostgreSQL
 * protocol byte stream and count {@code ParameterStatus} ('S') packets received from the server.
 *
 * The count for the most recently created socket can be read via {@link #getLatestCount()}.
 * The count can be reset to 0 via {@link #resetLatestCount()} so callers can measure counts for
 * specific intervals during a connection's lifetime.
 *
 * This is used to verify that connection manager does not forward {@code ParameterStatus} packets
 * to the external client when deploying a logical connection onto a physical backend.
 */
public class CountParameterStatusSocketFactory extends SocketFactory {
  private static final Logger LOG =
      LoggerFactory.getLogger(CountParameterStatusSocketFactory.class);

  // PostgreSQL ParameterStatus message type byte.
  private static final byte PARAMETER_STATUS = 'S';

  // Tracks the count of ParameterStatus packets observed on the most recently created socket.
  private static final AtomicInteger LATEST_COUNT = new AtomicInteger(0);

  private final SocketFactory defaultFactory = SocketFactory.getDefault();

  public CountParameterStatusSocketFactory() {
    super();
  }

  public static int getLatestCount() {
    return LATEST_COUNT.get();
  }

  public static void resetLatestCount() {
    LATEST_COUNT.set(0);
  }

  @Override
  public Socket createSocket() throws IOException {
    return new InspectingSocket();
  }

  @Override
  public Socket createSocket(String host, int port) throws IOException {
    return new InspectingSocket(host, port);
  }

  @Override
  public Socket createSocket(String host, int port, InetAddress localHost, int localPort)
      throws IOException {
    return new InspectingSocket(host, port, localHost, localPort);
  }

  @Override
  public Socket createSocket(InetAddress host, int port) throws IOException {
    return new InspectingSocket(host, port);
  }

  @Override
  public Socket createSocket(InetAddress address, int port, InetAddress localAddress, int localPort)
      throws IOException {
    return new InspectingSocket(address, port, localAddress, localPort);
  }

  /**
   * A socket whose input stream is a {@link CountingInputStream} that increments the
   * ParameterStatus count whenever it sees an 'S' packet header in the byte stream.
   */
  private static class InspectingSocket extends Socket {
    private CountingInputStream inputStream = null;

    public InspectingSocket() throws IOException {
      super();
    }

    public InspectingSocket(String host, int port) throws IOException {
      super(host, port);
    }

    public InspectingSocket(String host, int port, InetAddress localHost, int localPort)
        throws IOException {
      super(host, port, localHost, localPort);
    }

    public InspectingSocket(InetAddress host, int port) throws IOException {
      super(host, port);
    }

    public InspectingSocket(
        InetAddress address, int port, InetAddress localAddress, int localPort) throws IOException {
      super(address, port, localAddress, localPort);
    }

    @Override
    public InputStream getInputStream() throws IOException {
      if (inputStream == null) {
        inputStream = new CountingInputStream(super.getInputStream());
      }
      return inputStream;
    }

    @Override
    public OutputStream getOutputStream() throws IOException {
      return super.getOutputStream();
    }
  }

  /**
   * An InputStream that walks the Postgres v3 protocol byte stream and counts every
   * {@code ParameterStatus} ('S') message. We rely on the fact that all v3 messages from the
   * server start with a 1-byte type, followed by a 4-byte big-endian length (which includes
   * itself).
   */
  private static class CountingInputStream extends InputStream {
    private final InputStream delegate;

    // Parser state: how many more body bytes (including the 4-byte length field) of the current
    // message we still need to consume before we expect the next message-type byte.
    private long remainingBodyBytes = 0;
    // While reading the 4-byte length field, this holds bytes seen so far (0..4).
    private int lengthBytesSeen = 0;
    private long pendingLength = 0;
    private boolean awaitingType = true;

    public CountingInputStream(InputStream delegate) {
      this.delegate = delegate;
    }

    private void processByte(byte b) {
      if (awaitingType) {
        if (b == PARAMETER_STATUS) {
          int count = LATEST_COUNT.incrementAndGet();
          LOG.info("Observed ParameterStatus ('S') packet from server. Count = " + count);
        }
        awaitingType = false;
        lengthBytesSeen = 0;
        pendingLength = 0;
        return;
      }

      if (lengthBytesSeen < 4) {
        pendingLength = (pendingLength << 8) | (b & 0xFFL);
        lengthBytesSeen++;
        if (lengthBytesSeen == 4) {
          // Length field includes itself (4 bytes), so subtract them to get remaining body bytes.
          remainingBodyBytes = pendingLength - 4;
          if (remainingBodyBytes <= 0) {
            awaitingType = true;
          }
        }
        return;
      }

      remainingBodyBytes--;
      if (remainingBodyBytes <= 0) {
        awaitingType = true;
      }
    }

    @Override
    public int read() throws IOException {
      int b = delegate.read();
      if (b != -1) {
        processByte((byte) b);
      }
      return b;
    }

    @Override
    public int read(byte[] b) throws IOException {
      return read(b, 0, b.length);
    }

    @Override
    public int read(byte[] b, int off, int len) throws IOException {
      int bytesRead = delegate.read(b, off, len);
      if (bytesRead > 0) {
        for (int i = 0; i < bytesRead; i++) {
          processByte(b[off + i]);
        }
      }
      return bytesRead;
    }

    @Override
    public int available() throws IOException {
      return delegate.available();
    }

    @Override
    public void close() throws IOException {
      delegate.close();
    }

    @Override
    public synchronized void mark(int readlimit) {
      delegate.mark(readlimit);
    }

    @Override
    public synchronized void reset() throws IOException {
      delegate.reset();
    }

    @Override
    public boolean markSupported() {
      return delegate.markSupported();
    }
  }
}
