object BashServerMain {
  def main(args: Array[String]): Unit = {
    val server = isabelle.Bash.Server.start()
    val f = new java.io.PrintWriter(args(0))
    f.println(server.address)
    f.println(server.password)
    f.close()
    println("BASH_SERVER_READY")
    server.join()
  }
}
